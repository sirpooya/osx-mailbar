import Foundation
import os

/// Creating, changing, deleting and answering calendar events (M16, M17), plus the directory and
/// room lookups the event form uses. Every write is to the signed-in user's own calendar.
enum CalendarSOAP {

    // MARK: - Events

    /// `invite: false` saves without telling anyone yet: an event with files is created first,
    /// then given its files, then sent (`EWSClient.createEvent`), so the invitations carry them.
    static func createEvent(_ draft: EventDraft, invite: Bool = true) -> String {
        let invites = !invite || (draft.attendeeList.isEmpty && draft.rooms.isEmpty) ? "SendToNone" : "SendToAllAndSaveCopy"
        return """
            <m:CreateItem SendMeetingInvitations="\(invites)">
              <m:SavedItemFolderId><t:DistinguishedFolderId Id="calendar"/></m:SavedItemFolderId>
              <m:Items>
                <t:CalendarItem>
        \(itemFields(draft))
        \(recurrence(draft))
                </t:CalendarItem>
              </m:Items>
            </m:CreateItem>
        """
    }

    /// Every field the form edits, set at once. Meetings send updates to the people whose part
    /// changed; a plain appointment sends nothing.
    /// Changed files go to everyone (`sendToAll`), not only to the people whose part changed.
    static func updateEvent(_ draft: EventDraft, id: String, sendToAll: Bool = false) -> String {
        let sends = draft.attendeeList.isEmpty && draft.rooms.isEmpty ? "SendToNone"
            : sendToAll ? "SendToAllAndSaveCopy" : "SendToChangedAndSaveCopy"
        func set(_ field: String, _ element: String) -> String {
            """
                          <t:SetItemField><t:FieldURI FieldURI="\(field)"/><t:CalendarItem>\(element)</t:CalendarItem></t:SetItemField>
            """
        }
        var changes = [
            set("item:Subject", "<t:Subject>\(SOAP.escape(draft.subjectOrDefault))</t:Subject>"),
            set("item:Sensitivity", "<t:Sensitivity>\(draft.isPrivate ? "Private" : "Normal")</t:Sensitivity>"),
            set("item:Body", #"<t:Body BodyType="HTML">\#(SOAP.escape(ComposeHTML.html(from: draft.notes)))</t:Body>"#),
            set("item:ReminderIsSet", "<t:ReminderIsSet>\(draft.reminderMinutes != nil)</t:ReminderIsSet>"),
            set("calendar:Start", "<t:Start>\(SOAP.isoDate(draft.requestStart))</t:Start>"),
            set("calendar:End", "<t:End>\(SOAP.isoDate(draft.requestEnd))</t:End>"),
            set("calendar:IsAllDayEvent", "<t:IsAllDayEvent>\(draft.isAllDay)</t:IsAllDayEvent>"),
            set("calendar:LegacyFreeBusyStatus", "<t:LegacyFreeBusyStatus>\(draft.showAs.rawValue)</t:LegacyFreeBusyStatus>"),
            set("calendar:Location", "<t:Location>\(SOAP.escape(draft.locationText))</t:Location>"),
        ]
        if let minutes = draft.reminderMinutes {
            changes.append(set("item:ReminderMinutesBeforeStart",
                               "<t:ReminderMinutesBeforeStart>\(minutes)</t:ReminderMinutesBeforeStart>"))
        }
        changes.append(draft.categories.isEmpty
            ? #"              <t:DeleteItemField><t:FieldURI FieldURI="item:Categories"/></t:DeleteItemField>"#
            : set("item:Categories", categories(draft.categories)))
        changes.append(set("calendar:IsResponseRequested",
                           "<t:IsResponseRequested>\(draft.requestResponses)</t:IsResponseRequested>"))
        changes.append("""
                      <t:SetItemField>\(EventCharm.doNotForwardURI)<t:CalendarItem>\(doNotForward(draft))</t:CalendarItem></t:SetItemField>
        """)
        changes.append(draft.charm.map { charm in
            """
                          <t:SetItemField>\(EventCharm.fieldURI)<t:CalendarItem>\(charmProperty(charm))</t:CalendarItem></t:SetItemField>
            """
        } ?? "              <t:DeleteItemField>\(EventCharm.fieldURI)</t:DeleteItemField>")
        changes.append(draft.attendeeList.isEmpty
            ? #"              <t:DeleteItemField><t:FieldURI FieldURI="calendar:RequiredAttendees"/></t:DeleteItemField>"#
            : set("calendar:RequiredAttendees", "<t:RequiredAttendees>\(attendees(draft.attendeeList))</t:RequiredAttendees>"))
        changes.append(draft.rooms.isEmpty
            ? #"              <t:DeleteItemField><t:FieldURI FieldURI="calendar:Resources"/></t:DeleteItemField>"#
            : set("calendar:Resources", "<t:Resources>\(attendees(draft.rooms.map(\.address)))</t:Resources>"))
        return """
            <m:UpdateItem ConflictResolution="AlwaysOverwrite" SendMeetingInvitationsOrCancellations="\(sends)">
              <m:ItemChanges>
                <t:ItemChange>
                  <t:ItemId Id="\(SOAP.escape(id))"/>
                  <t:Updates>
        \(changes.joined(separator: "\n"))
                  </t:Updates>
                </t:ItemChange>
              </m:ItemChanges>
            </m:UpdateItem>
        """
    }

    /// To Deleted Items, as Outlook's Delete does. A meeting the user organized sends everyone the
    /// cancellation; anything else tells nobody.
    static func deleteEvent(id: String, cancelMeeting: Bool) -> String {
        """
            <m:DeleteItem DeleteType="MoveToDeletedItems" SendMeetingCancellations="\(cancelMeeting ? "SendToAllAndSaveCopy" : "SendToNone")">
              <m:ItemIds><t:ItemId Id="\(SOAP.escape(id))"/></m:ItemIds>
            </m:DeleteItem>
        """
    }

    // MARK: - Attachments

    /// Files added to an event, in one request. The bytes go Base64 in the XML, as EWS takes them.
    static func createAttachments(_ files: [EventDraft.NewFile], parent id: String) -> String {
        let items = files.map { file in
            "<t:FileAttachment><t:Name>\(SOAP.escape(file.name))</t:Name><t:Content>\(file.data.base64EncodedString())</t:Content></t:FileAttachment>"
        }.joined(separator: "\n        ")
        return """
            <m:CreateAttachment>
              <m:ParentItemId Id="\(SOAP.escape(id))"/>
              <m:Attachments>
                \(items)
              </m:Attachments>
            </m:CreateAttachment>
        """
    }

    static func deleteAttachments(_ ids: [String]) -> String {
        """
            <m:DeleteAttachment>
              <m:AttachmentIds>\(ids.map { #"<t:AttachmentId Id="\#(SOAP.escape($0))"/>"# }.joined())</m:AttachmentIds>
            </m:DeleteAttachment>
        """
    }

    // MARK: - Availability

    /// Free or busy for each person over `start..<end`, for the People sidebar. Times go as UTC,
    /// with a zero-bias zone, so nothing depends on the server's idea of the user's zone. The
    /// window is whole days, which every Exchange version accepts.
    static func availability(_ addresses: [String], start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let from = utc.startOfDay(for: start)
        let to = utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: max(end, start))) ?? end
        let zone = "<t:Bias>0</t:Bias><t:StandardTime><t:Bias>0</t:Bias><t:Time>02:00:00</t:Time><t:DayOrder>5</t:DayOrder><t:Month>10</t:Month><t:DayOfWeek>Sunday</t:DayOfWeek></t:StandardTime><t:DaylightTime><t:Bias>0</t:Bias><t:Time>02:00:00</t:Time><t:DayOrder>1</t:DayOrder><t:Month>4</t:Month><t:DayOfWeek>Sunday</t:DayOfWeek></t:DaylightTime>"
        let mailboxes = addresses.map {
            "<t:MailboxData><t:Email><t:Address>\(SOAP.escape($0))</t:Address></t:Email><t:AttendeeType>Required</t:AttendeeType><t:ExcludeConflicts>false</t:ExcludeConflicts></t:MailboxData>"
        }.joined()
        return """
            <m:GetUserAvailabilityRequest>
              <t:TimeZone>\(zone)</t:TimeZone>
              <m:MailboxDataArray>\(mailboxes)</m:MailboxDataArray>
              <t:FreeBusyViewOptions>
                <t:TimeWindow><t:StartTime>\(formatter.string(from: from))</t:StartTime><t:EndTime>\(formatter.string(from: to))</t:EndTime></t:TimeWindow>
                <t:MergedFreeBusyIntervalInMinutes>30</t:MergedFreeBusyIntervalInMinutes>
                <t:RequestedView>FreeBusy</t:RequestedView>
              </t:FreeBusyViewOptions>
            </m:GetUserAvailabilityRequest>
        """
    }

    // MARK: - Photos

    /// A person's photo as Exchange 2013 and later keep it (from the mailbox or the directory),
    /// 96 pixels square.
    static func getUserPhoto(_ address: String) -> String {
        """
            <m:GetUserPhoto>
              <m:Email>\(SOAP.escape(address))</m:Email>
              <m:SizeRequested>HR96x96</m:SizeRequested>
            </m:GetUserPhoto>
        """
    }

    // MARK: - Answering (M17)

    enum Answer: String, CaseIterable, Sendable {
        case accept = "AcceptItem"
        case tentative = "TentativelyAcceptItem"
        case decline = "DeclineItem"

        var label: String {
            switch self {
            case .accept: return "Accept"
            case .tentative: return "Tentative"
            case .decline: return "Decline"
            }
        }

        /// For the confirmation line.
        var done: String {
            switch self {
            case .accept: return "Accepted"
            case .tentative: return "Tentatively accepted"
            case .decline: return "Declined"
            }
        }

        /// The `MyResponseType` the server reports once this answer is in.
        var responseType: String {
            switch self {
            case .accept: return "Accept"
            case .tentative: return "Tentative"
            case .decline: return "Decline"
            }
        }
    }

    /// Answers an invitation, from the calendar event or from the invitation email; either id
    /// works as the reference. The organizer receives the answer, with the note if there is one.
    static func answer(_ answer: Answer, to id: String, changeKey: String, note: String) -> String {
        let body = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : #"<t:Body BodyType="HTML">\#(SOAP.escape(ComposeHTML.html(from: note)))</t:Body>"#
        return """
            <m:CreateItem MessageDisposition="SendAndSaveCopy">
              <m:Items>
                <t:\(answer.rawValue)>
                  \(body)
                  <t:ReferenceItemId Id="\(SOAP.escape(id))" ChangeKey="\(SOAP.escape(changeKey))"/>
                </t:\(answer.rawValue)>
              </m:Items>
            </m:CreateItem>
        """
    }

    // MARK: - Directory and rooms

    /// The company directory, searched by the server itself (no LDAP client here): the same
    /// lookup Outlook's "Suggested contacts" does.
    static func resolveNames(_ text: String) -> String {
        """
            <m:ResolveNames ReturnFullContactData="false" SearchScope="ActiveDirectory">
              <m:UnresolvedEntry>\(SOAP.escape(text))</m:UnresolvedEntry>
            </m:ResolveNames>
        """
    }

    /// A distribution group's members, one level down (a group inside is listed as a group).
    static func expandGroup(_ address: String) -> String {
        """
            <m:ExpandDL>
              <m:Mailbox><t:EmailAddress>\(SOAP.escape(address))</t:EmailAddress></m:Mailbox>
            </m:ExpandDL>
        """
    }

    static let getRoomLists = "    <m:GetRoomLists/>"

    static func getRooms(list address: String) -> String {
        """
            <m:GetRooms>
              <m:RoomList><t:EmailAddress>\(SOAP.escape(address))</t:EmailAddress></m:RoomList>
            </m:GetRooms>
        """
    }

    // MARK: - Pieces

    /// `ItemType` fields first, then `CalendarItemType`'s, in the schema's order.
    private static func itemFields(_ draft: EventDraft) -> String {
        var lines = [
            "<t:Subject>\(SOAP.escape(draft.subjectOrDefault))</t:Subject>",
            "<t:Sensitivity>\(draft.isPrivate ? "Private" : "Normal")</t:Sensitivity>",
            #"<t:Body BodyType="HTML">\#(SOAP.escape(ComposeHTML.html(from: draft.notes)))</t:Body>"#,
        ]
        if !draft.categories.isEmpty { lines.append(categories(draft.categories)) }
        lines.append("<t:ReminderIsSet>\(draft.reminderMinutes != nil)</t:ReminderIsSet>")
        if let minutes = draft.reminderMinutes {
            lines.append("<t:ReminderMinutesBeforeStart>\(minutes)</t:ReminderMinutesBeforeStart>")
        }
        if let charm = draft.charm { lines.append(charmProperty(charm)) }
        lines.append(doNotForward(draft))
        lines += [
            "<t:Start>\(SOAP.isoDate(draft.requestStart))</t:Start>",
            "<t:End>\(SOAP.isoDate(draft.requestEnd))</t:End>",
            "<t:IsAllDayEvent>\(draft.isAllDay)</t:IsAllDayEvent>",
            "<t:LegacyFreeBusyStatus>\(draft.showAs.rawValue)</t:LegacyFreeBusyStatus>",
            "<t:Location>\(SOAP.escape(draft.locationText))</t:Location>",
            // After Location and before the attendees, in CalendarItemType's order.
            "<t:IsResponseRequested>\(draft.requestResponses)</t:IsResponseRequested>",
        ]
        if !draft.attendeeList.isEmpty {
            lines.append("<t:RequiredAttendees>\(attendees(draft.attendeeList))</t:RequiredAttendees>")
        }
        if !draft.rooms.isEmpty {
            lines.append("<t:Resources>\(attendees(draft.rooms.map(\.address)))</t:Resources>")
        }
        return lines.map { "          " + $0 }.joined(separator: "\n")
    }

    private static func categories(_ names: [String]) -> String {
        "<t:Categories>" + names.map { "<t:String>\(SOAP.escape($0))</t:String>" }.joined() + "</t:Categories>"
    }

    private static func doNotForward(_ draft: EventDraft) -> String {
        "<t:ExtendedProperty>\(EventCharm.doNotForwardURI)<t:Value>\(!draft.allowForwarding)</t:Value></t:ExtendedProperty>"
    }

    private static func charmProperty(_ charm: Int) -> String {
        "<t:ExtendedProperty>\(EventCharm.fieldURI)<t:Value>\(charm)</t:Value></t:ExtendedProperty>"
    }

    private static func attendees(_ addresses: [String]) -> String {
        addresses.map { "<t:Attendee><t:Mailbox><t:EmailAddress>\(SOAP.escape($0))</t:EmailAddress></t:Mailbox></t:Attendee>" }.joined()
    }

    private static func recurrence(_ draft: EventDraft) -> String {
        guard draft.id == nil, let pattern = draft.repeatPattern else { return "" }
        let start = draft.requestStart
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let from = "<t:StartDate>\(formatter.string(from: start))</t:StartDate>"
        let range: String
        switch draft.repeatEnd {
        case .never:
            range = "<t:NoEndRecurrence>\(from)</t:NoEndRecurrence>"
        case .on(let last):
            range = "<t:EndDateRecurrence>\(from)<t:EndDate>\(formatter.string(from: last))</t:EndDate></t:EndDateRecurrence>"
        case .after(let count):
            range = "<t:NumberedRecurrence>\(from)<t:NumberOfOccurrences>\(max(count, 1))</t:NumberOfOccurrences></t:NumberedRecurrence>"
        }
        return "          <t:Recurrence>\(pattern.xml(start: start))\(range)</t:Recurrence>"
    }
}

/// Windows time zone ids, which Exchange wants in `TimeZoneContext` so that an all-day event and
/// a repeating one land on the user's own days, not UTC's.
enum WindowsTimeZone {
    static let byIANA: [String: String] = [
        "Asia/Tehran": "Iran Standard Time",
        "Asia/Dubai": "Arabian Standard Time",
        "Asia/Kolkata": "India Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time",
        "Europe/Istanbul": "Turkey Standard Time",
        "Asia/Istanbul": "Turkey Standard Time",
        "Europe/London": "GMT Standard Time",
        "Europe/Berlin": "W. Europe Standard Time",
        "Europe/Amsterdam": "W. Europe Standard Time",
        "Europe/Paris": "Romance Standard Time",
        "America/New_York": "Eastern Standard Time",
        "America/Chicago": "Central Standard Time",
        "America/Denver": "Mountain Standard Time",
        "America/Los_Angeles": "Pacific Standard Time",
        "UTC": "UTC",
        "GMT": "UTC",
    ]

    static var current: String? { byIANA[TimeZone.current.identifier] }
}

struct Room: Equatable, Hashable, Identifiable, Sendable {
    let name: String
    let address: String
    var id: String { address }
}

extension EWSResponse {
    /// Directory matches. "No results" is an empty list, not an error.
    static func resolvedNames(from data: Data) throws -> [PersonSuggestion] {
        let root = try parse(data)
        if root.first("ResponseCode")?.trimmedText == "ErrorNameResolutionNoResults" { return [] }
        _ = try responseMessages(in: root)
        return root.all("Resolution").compactMap { $0.child("Mailbox").flatMap(person) }
    }

    /// A group's members, and whether the server listed them all.
    static func groupMembers(from data: Data) throws -> (members: [PersonSuggestion], complete: Bool) {
        let root = try parse(data)
        _ = try responseMessages(in: root)
        let expansion = root.first("DLExpansion")
        let members = (expansion?.all("Mailbox") ?? []).compactMap(person)
        return (members, expansion?.attributes["IncludesLastItemInRange"] != "false")
    }

    /// `PublicDL` is a directory group, `PrivateDL` one saved in someone's contacts.
    private static func person(_ mailbox: XMLTreeNode) -> PersonSuggestion? {
        guard let address = mailbox.child("EmailAddress")?.trimmedText, !address.isEmpty else { return nil }
        let type = mailbox.child("MailboxType")?.trimmedText ?? ""
        return PersonSuggestion(name: mailbox.child("Name")?.trimmedText ?? "", address: address,
                                isGroup: type == "PublicDL" || type == "PrivateDL")
    }

    /// One state per address, in request order, as the reply lists them: `Free`, `Tentative`,
    /// `Busy`, `OOF`, `WorkingElsewhere`, or `NoData` when the server could not say.
    static func availability(from data: Data, addresses: [String], start: Date, end: Date) throws -> [String: String] {
        let root = try parse(data)
        let rank = ["Free": 0, "WorkingElsewhere": 1, "Tentative": 2, "Busy": 3, "OOF": 4]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func date(_ text: String) -> Date? { parseDate(text) ?? formatter.date(from: String(text.prefix(19))) }
        var result: [String: String] = [:]
        for (address, response) in zip(addresses, root.all("FreeBusyResponse")) {
            guard response.child("ResponseMessage")?.attributes["ResponseClass"] != "Error" else {
                result[address.lowercased()] = "NoData"
                continue
            }
            var state = "Free"
            for event in response.all("CalendarEvent") {
                guard let from = event.child("StartTime").flatMap({ date($0.trimmedText) }),
                      let to = event.child("EndTime").flatMap({ date($0.trimmedText) }),
                      from < end, to > start else { continue }
                let type = event.child("BusyType")?.trimmedText ?? "Busy"
                if (rank[type] ?? 0) > (rank[state] ?? 0) { state = type }
            }
            result[address.lowercased()] = state
        }
        return result
    }

    static func roomAddresses(from data: Data, element: String) throws -> [Room] {
        let root = try parse(data)
        if root.first("ResponseCode")?.trimmedText.hasPrefix("Error") == true { return [] }
        return root.all(element).compactMap { node in
            let box = node.child("Id") ?? node
            guard let address = box.child("EmailAddress")?.trimmedText, !address.isEmpty else { return nil }
            return Room(name: box.child("Name")?.trimmedText ?? address, address: address)
        }
    }
}

extension EWSClient {
    static let photoLog = Logger(subsystem: "in.pooya.mailbar", category: "photos")

    /// With files, three steps, as Exchange's own API does it: save the event telling nobody,
    /// attach the files, then send the invitations, so they arrive with the files in them.
    func createEvent(_ draft: EventDraft, at url: URL, credential: EWSCredential) async throws {
        guard !draft.newFiles.isEmpty else {
            try await calendarWrite(CalendarSOAP.createEvent(draft), url: url, credential: credential)
            return
        }
        let created = try await raw(CalendarSOAP.createEvent(draft, invite: false), url: url, credential: credential)
        let root = try EWSResponse.parse(created)
        _ = try EWSResponse.responseMessages(in: root)
        guard let id = root.first("ItemId")?.attributes["Id"] else {
            throw EWSError.invalidResponse("Exchange did not return the new event.")
        }
        try await calendarWrite(CalendarSOAP.createAttachments(draft.newFiles, parent: id), url: url, credential: credential)
        if draft.sendsInvitations {
            try await calendarWrite(CalendarSOAP.updateEvent(draft, id: id, sendToAll: true), url: url, credential: credential)
        }
    }

    /// Files first, removed then added, so the update that follows sends the event as it now is.
    func updateEvent(_ draft: EventDraft, id: String, at url: URL, credential: EWSCredential) async throws {
        if !draft.removedFileIDs.isEmpty {
            try await calendarWrite(CalendarSOAP.deleteAttachments(Array(draft.removedFileIDs)), url: url, credential: credential)
        }
        if !draft.newFiles.isEmpty {
            try await calendarWrite(CalendarSOAP.createAttachments(draft.newFiles, parent: id), url: url, credential: credential)
        }
        try await calendarWrite(CalendarSOAP.updateEvent(draft, id: id, sendToAll: draft.changesFiles),
                                url: url, credential: credential)
    }

    /// The photo's bytes, or nil when the person has none (Exchange answers with an error then).
    /// Needs Exchange 2013; the caller checks the version first.
    func userPhoto(_ address: String, at url: URL, credential: EWSCredential) async throws -> Data? {
        let data = try await sendRaw(SOAP.envelope(.exchange2013, body: CalendarSOAP.getUserPhoto(address)),
                                     to: url, credential: credential)
        let root = try EWSResponse.parse(data)
        guard let picture = root.first("PictureData")?.trimmedText, !picture.isEmpty else {
            // Why there is none, for Console: a person without a photo says ErrorItemNotFound,
            // anything else is the server refusing. The address stays private in the log.
            let code = root.first("ResponseCode")?.trimmedText ?? "no ResponseCode"
            Self.photoLog.info("No photo for \(address, privacy: .private): \(code, privacy: .public)")
            return nil
        }
        return Data(base64Encoded: picture)
    }

    /// Each address's state over the event's time: the busiest thing they have in it.
    func availability(_ addresses: [String], start: Date, end: Date, at url: URL,
                      credential: EWSCredential) async throws -> [String: String] {
        // No time zone header: the request carries its own zone, UTC, and the header would compete.
        let data = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: CalendarSOAP.availability(addresses, start: start, end: end),
                                                   timeZone: nil), to: url, credential: credential)
        return try EWSResponse.availability(from: data, addresses: addresses, start: start, end: end)
    }

    func deleteEvent(id: String, cancelMeeting: Bool, at url: URL, credential: EWSCredential) async throws {
        try await calendarWrite(CalendarSOAP.deleteEvent(id: id, cancelMeeting: cancelMeeting), url: url, credential: credential)
    }

    /// Reads the item's current change key first: an answer must name the exact version it answers.
    func answer(_ answer: CalendarSOAP.Answer, to id: String, note: String, at url: URL, credential: EWSCredential) async throws {
        let identity = try await raw(SOAP.getItemIdentity(id: id), url: url, credential: credential)
        let root = try EWSResponse.parse(identity)
        _ = try EWSResponse.responseMessages(in: root)
        guard let changeKey = root.first("ItemId")?.attributes["ChangeKey"] else {
            throw EWSError.invalidResponse("Exchange did not return the invitation.")
        }
        try await calendarWrite(CalendarSOAP.answer(answer, to: id, changeKey: changeKey, note: note),
                                url: url, credential: credential)
    }

    func resolveNames(_ text: String, at url: URL, credential: EWSCredential) async throws -> [PersonSuggestion] {
        try EWSResponse.resolvedNames(from: try await raw(CalendarSOAP.resolveNames(text), url: url, credential: credential))
    }

    func expandGroup(_ address: String, at url: URL, credential: EWSCredential) async throws -> (members: [PersonSuggestion], complete: Bool) {
        try EWSResponse.groupMembers(from: try await raw(CalendarSOAP.expandGroup(address), url: url, credential: credential))
    }

    /// Every room in every room list the organization publishes. Empty when it publishes none.
    func rooms(at url: URL, credential: EWSCredential) async throws -> [Room] {
        let lists = try EWSResponse.roomAddresses(from: try await raw(CalendarSOAP.getRoomLists, url: url, credential: credential),
                                                  element: "Address")
        var rooms: [Room] = []
        for list in lists {
            let data = try await raw(CalendarSOAP.getRooms(list: list.address), url: url, credential: credential)
            rooms += try EWSResponse.roomAddresses(from: data, element: "Room")
        }
        return Array(Set(rooms)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func calendarWrite(_ body: String, url: URL, credential: EWSCredential) async throws {
        try EWSResponse.checkSuccess(try await raw(body, url: url, credential: credential))
    }

    /// With the user's time zone in the header, so all-day and repeating events keep their days.
    private func raw(_ body: String, url: URL, credential: EWSCredential) async throws -> Data {
        try await sendRaw(SOAP.envelope(.exchange2010SP2, body: body, timeZone: WindowsTimeZone.current),
                          to: url, credential: credential)
    }
}
