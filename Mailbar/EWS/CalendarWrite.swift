import Foundation

/// Creating, changing, deleting and answering calendar events (M16, M17), plus the directory and
/// room lookups the event form uses. Every write is to the signed-in user's own calendar.
enum CalendarSOAP {

    // MARK: - Events

    static func createEvent(_ draft: EventDraft) -> String {
        let invites = draft.attendeeList.isEmpty && draft.rooms.isEmpty ? "SendToNone" : "SendToAllAndSaveCopy"
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
    static func updateEvent(_ draft: EventDraft, id: String) -> String {
        let sends = draft.attendeeList.isEmpty && draft.rooms.isEmpty ? "SendToNone" : "SendToChangedAndSaveCopy"
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
            "<t:ReminderIsSet>\(draft.reminderMinutes != nil)</t:ReminderIsSet>",
        ]
        if let minutes = draft.reminderMinutes {
            lines.append("<t:ReminderMinutesBeforeStart>\(minutes)</t:ReminderMinutesBeforeStart>")
        }
        lines += [
            "<t:Start>\(SOAP.isoDate(draft.requestStart))</t:Start>",
            "<t:End>\(SOAP.isoDate(draft.requestEnd))</t:End>",
            "<t:IsAllDayEvent>\(draft.isAllDay)</t:IsAllDayEvent>",
            "<t:LegacyFreeBusyStatus>\(draft.showAs.rawValue)</t:LegacyFreeBusyStatus>",
            "<t:Location>\(SOAP.escape(draft.locationText))</t:Location>",
        ]
        if !draft.attendeeList.isEmpty {
            lines.append("<t:RequiredAttendees>\(attendees(draft.attendeeList))</t:RequiredAttendees>")
        }
        if !draft.rooms.isEmpty {
            lines.append("<t:Resources>\(attendees(draft.rooms.map(\.address)))</t:Resources>")
        }
        return lines.map { "          " + $0 }.joined(separator: "\n")
    }

    private static func attendees(_ addresses: [String]) -> String {
        addresses.map { "<t:Attendee><t:Mailbox><t:EmailAddress>\(SOAP.escape($0))</t:EmailAddress></t:Mailbox></t:Attendee>" }.joined()
    }

    private static func recurrence(_ draft: EventDraft) -> String {
        guard draft.id == nil, draft.repeatRule != .never else { return "" }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let start = draft.requestStart
        let day = calendar.component(.day, from: start)
        let weekday = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][calendar.component(.weekday, from: start) - 1]
        let month = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                     "October", "November", "December"][calendar.component(.month, from: start) - 1]
        let pattern: String
        switch draft.repeatRule {
        case .never: return ""
        case .daily: pattern = "<t:DailyRecurrence><t:Interval>1</t:Interval></t:DailyRecurrence>"
        case .weekly: pattern = "<t:WeeklyRecurrence><t:Interval>1</t:Interval><t:DaysOfWeek>\(weekday)</t:DaysOfWeek></t:WeeklyRecurrence>"
        case .monthly: pattern = "<t:AbsoluteMonthlyRecurrence><t:Interval>1</t:Interval><t:DayOfMonth>\(day)</t:DayOfMonth></t:AbsoluteMonthlyRecurrence>"
        case .yearly: pattern = "<t:AbsoluteYearlyRecurrence><t:DayOfMonth>\(day)</t:DayOfMonth><t:Month>\(month)</t:Month></t:AbsoluteYearlyRecurrence>"
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "          <t:Recurrence>\(pattern)<t:NoEndRecurrence><t:StartDate>\(formatter.string(from: start))</t:StartDate></t:NoEndRecurrence></t:Recurrence>"
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
    static func resolvedNames(from data: Data) throws -> [(name: String, address: String)] {
        let root = try parse(data)
        if root.first("ResponseCode")?.trimmedText == "ErrorNameResolutionNoResults" { return [] }
        _ = try responseMessages(in: root)
        return root.all("Resolution").compactMap { resolution in
            guard let mailbox = resolution.child("Mailbox"),
                  let address = mailbox.child("EmailAddress")?.trimmedText, !address.isEmpty else { return nil }
            return (mailbox.child("Name")?.trimmedText ?? "", address)
        }
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
    func createEvent(_ draft: EventDraft, at url: URL, credential: EWSCredential) async throws {
        try await calendarWrite(CalendarSOAP.createEvent(draft), url: url, credential: credential)
    }

    func updateEvent(_ draft: EventDraft, id: String, at url: URL, credential: EWSCredential) async throws {
        try await calendarWrite(CalendarSOAP.updateEvent(draft, id: id), url: url, credential: credential)
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

    func resolveNames(_ text: String, at url: URL, credential: EWSCredential) async throws -> [(name: String, address: String)] {
        try EWSResponse.resolvedNames(from: try await raw(CalendarSOAP.resolveNames(text), url: url, credential: credential))
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
