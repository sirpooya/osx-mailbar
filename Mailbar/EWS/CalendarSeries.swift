import Foundation

// Outlook's calendar extras (2026-11-16): editing or deleting a whole series or this and the
// following occurrences, attendees' proposed times, moving a meeting to one, and exporting an
// event as an .ics file. Every write is to the signed-in user's own calendar.

/// Which part of a repeating event an edit or a delete applies to, Outlook's three choices.
enum SeriesScope: String, CaseIterable, Identifiable, Sendable {
    case occurrence, following, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .occurrence: return "This Event"
        case .following: return "This and Following"
        case .all: return "All Events"
        }
    }
}

/// A series as its master holds it: the master's details, its rule and how it ends.
struct SeriesMaster: Equatable, Sendable {
    var detail: EventDetail
    /// Nil for a rule this app cannot draw (a relative yearly one): the series can still be
    /// deleted, but its rule is not rewritten here.
    var pattern: RepeatPattern?
    var end: RepeatEnd
    /// The rule's StartDate exactly as the server wrote it ("2026-09-01+03:30").
    var startDateText: String
}

/// "This and Following": the series being cut, so that saving ends it on the day before the
/// occurrence and the edited event goes on as a new series from there.
struct SeriesSplit: Equatable, Sendable {
    let masterID: String
    let pattern: RepeatPattern
    /// The master's own start, which the rule's days are worked out from.
    let patternStart: Date
    let startDateText: String
    /// The old series' last day.
    let lastDay: Date
    /// The old series is a meeting with people: they are told it now ends.
    let notifies: Bool
}

/// An attendee's proposed new time, from their answer in the Inbox (Exchange 2013 and later).
struct TimeProposal: Equatable, Identifiable, Sendable {
    /// The answer email's id.
    let id: String
    let name: String
    let address: String
    let start: Date
    let end: Date
    var display: String { name.isEmpty ? address : name }
}

extension CalendarSOAP {
    /// The fields of a series master, as `getEvent` reads an event, plus its rule.
    private static let masterFields = [
        "item:Subject", "calendar:Start", "calendar:End", "calendar:IsAllDayEvent", "calendar:Location",
        "calendar:Organizer", "calendar:IsRecurring", "calendar:IsMeeting", "calendar:IsCancelled",
        "calendar:MyResponseType", "calendar:LegacyFreeBusyStatus", "calendar:CalendarItemType",
        "item:Sensitivity", "item:Categories", "item:ReminderIsSet", "item:ReminderMinutesBeforeStart",
        "item:Body", "calendar:RequiredAttendees", "calendar:OptionalAttendees", "calendar:Resources",
        "item:Attachments", "calendar:IsResponseRequested", "calendar:Recurrence",
    ].map { "          <t:FieldURI FieldURI=\"\($0)\"/>" }.joined(separator: "\n")

    /// The series an occurrence belongs to, found from the occurrence's own id.
    static func getMaster(occurrenceID: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:BodyType>HTML</t:BodyType>
                <t:AdditionalProperties>
        \(masterFields)
                  \(EventCharm.fieldURI)
                  \(EventCharm.doNotForwardURI)
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds><t:RecurringMasterItemId OccurrenceId="\(SOAP.escape(occurrenceID))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    /// The whole series to Deleted Items, named by one of its occurrences. A meeting the user
    /// organized tells everyone it is cancelled.
    static func deleteSeries(occurrenceID: String, cancelMeeting: Bool) -> String {
        """
            <m:DeleteItem DeleteType="MoveToDeletedItems" SendMeetingCancellations="\(cancelMeeting ? "SendToAllAndSaveCopy" : "SendToNone")">
              <m:ItemIds><t:RecurringMasterItemId OccurrenceId="\(SOAP.escape(occurrenceID))"/></m:ItemIds>
            </m:DeleteItem>
        """
    }

    /// Ends a series on `lastDay`, keeping its rule: the first half of "This and Following".
    static func endSeries(_ split: SeriesSplit, calendar: Calendar = .current) -> String {
        """
            <m:UpdateItem ConflictResolution="AlwaysOverwrite" SendMeetingInvitationsOrCancellations="\(split.notifies ? "SendToAllAndSaveCopy" : "SendToNone")">
              <m:ItemChanges>
                <t:ItemChange>
                  <t:ItemId Id="\(SOAP.escape(split.masterID))"/>
                  <t:Updates>
                    <t:SetItemField><t:FieldURI FieldURI="calendar:Recurrence"/><t:CalendarItem><t:Recurrence>\(split.pattern.xml(start: split.patternStart, calendar: calendar))<t:EndDateRecurrence><t:StartDate>\(SOAP.escape(split.startDateText))</t:StartDate><t:EndDate>\(dayText(split.lastDay, calendar: calendar))</t:EndDate></t:EndDateRecurrence></t:Recurrence></t:CalendarItem></t:SetItemField>
                  </t:Updates>
                </t:ItemChange>
              </m:ItemChanges>
            </m:UpdateItem>
        """
    }

    /// Moves a meeting to a new time and sends everyone the update: accepting a proposal.
    static func moveEvent(id: String, start: Date, end: Date, notify: Bool) -> String {
        """
            <m:UpdateItem ConflictResolution="AlwaysOverwrite" SendMeetingInvitationsOrCancellations="\(notify ? "SendToAllAndSaveCopy" : "SendToNone")">
              <m:ItemChanges>
                <t:ItemChange>
                  <t:ItemId Id="\(SOAP.escape(id))"/>
                  <t:Updates>
                    <t:SetItemField><t:FieldURI FieldURI="calendar:Start"/><t:CalendarItem><t:Start>\(SOAP.isoDate(start))</t:Start></t:CalendarItem></t:SetItemField>
                    <t:SetItemField><t:FieldURI FieldURI="calendar:End"/><t:CalendarItem><t:End>\(SOAP.isoDate(end))</t:End></t:CalendarItem></t:SetItemField>
                  </t:Updates>
                </t:ItemChange>
              </m:ItemChanges>
            </m:UpdateItem>
        """
    }

    /// Answers to the user's meetings in the Inbox, newest first: the meeting response classes
    /// (`IPM.Schedule.Meeting.Resp.Pos`, `.Tent`, `.Neg`) all start the same way.
    static let findMeetingResponses = """
        <m:FindItem Traversal="Shallow">
          <m:ItemShape>
            <t:BaseShape>IdOnly</t:BaseShape>
            <t:AdditionalProperties>
              <t:FieldURI FieldURI="item:Subject"/>
              <t:FieldURI FieldURI="item:ItemClass"/>
            </t:AdditionalProperties>
          </m:ItemShape>
          <m:IndexedPageItemView MaxEntriesReturned="100" Offset="0" BasePoint="Beginning"/>
          <m:Restriction>
            <t:Contains ContainmentMode="Prefixed" ContainmentComparison="IgnoreCase">
              <t:FieldURI FieldURI="item:ItemClass"/>
              <t:Constant Value="IPM.Schedule.Meeting.Resp"/>
            </t:Contains>
          </m:Restriction>
          <m:SortOrder><t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder></m:SortOrder>
          <m:ParentFolderIds><t:DistinguishedFolderId Id="inbox"/></m:ParentFolderIds>
        </m:FindItem>
    """

    /// Each answer's sender, the meeting it is for and the time it proposes (Exchange 2013).
    static func getProposals(ids: [String]) -> String {
        """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
                  <t:FieldURI FieldURI="item:Subject"/>
                  <t:FieldURI FieldURI="message:From"/>
                  <t:FieldURI FieldURI="meeting:AssociatedCalendarItemId"/>
                  <t:FieldURI FieldURI="meetingResponse:ProposedStart"/>
                  <t:FieldURI FieldURI="meetingResponse:ProposedEnd"/>
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds>\(ids.map { #"<t:ItemId Id="\#(SOAP.escape($0))"/>"# }.joined())</m:ItemIds>
            </m:GetItem>
        """
    }

    /// The event as the server writes it out, an iCalendar file (`MimeContent`).
    static func exportEvent(id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:IncludeMimeContent>true</t:IncludeMimeContent>
              </m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(SOAP.escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    static func dayText(_ day: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}

extension RepeatPattern {
    /// A `<t:Recurrence>`'s pattern, when it is one the form can draw.
    static func parse(_ recurrence: XMLTreeNode) -> RepeatPattern? {
        guard let node = recurrence.children.first(where: { $0.name.hasSuffix("Recurrence") && !$0.name.contains("End")
                                                         && $0.name != "NumberedRecurrence" }) else { return nil }
        let interval = node.child("Interval").flatMap { Int($0.trimmedText) } ?? 1
        switch node.name {
        case "DailyRecurrence":
            return RepeatPattern(kind: .daily, interval: interval)
        case "WeeklyRecurrence":
            return RepeatPattern(kind: .weekly, interval: interval,
                                 weekdays: weekdays(node.child("DaysOfWeek")?.trimmedText ?? ""))
        case "AbsoluteMonthlyRecurrence":
            return RepeatPattern(kind: .monthlyDay, interval: interval)
        case "RelativeMonthlyRecurrence":
            return RepeatPattern(kind: .monthlyWeek, interval: interval)
        case "AbsoluteYearlyRecurrence":
            return RepeatPattern(kind: .yearly)
        default:
            return nil
        }
    }

    /// "Monday Wednesday", or the schema's groups, as Calendar weekdays (1 Sunday ... 7 Saturday).
    static func weekdays(_ text: String) -> Set<Int> {
        var days: Set<Int> = []
        for word in text.split(separator: " ") {
            switch word {
            case "Day": days.formUnion(1...7)
            case "Weekday": days.formUnion(2...6)
            case "WeekendDay": days.formUnion([1, 7])
            default:
                if let index = dayNames.firstIndex(of: String(word)) { days.insert(index + 1) }
            }
        }
        return days
    }

    /// How the series ends, from the rule's range element.
    static func parseEnd(_ recurrence: XMLTreeNode, calendar: Calendar = .current) -> (RepeatEnd, String) {
        if let range = recurrence.child("EndDateRecurrence") {
            let start = range.child("StartDate")?.trimmedText ?? ""
            let end = range.child("EndDate").flatMap { day($0.trimmedText, calendar: calendar) }
            return (end.map(RepeatEnd.on) ?? .never, start)
        }
        if let range = recurrence.child("NumberedRecurrence") {
            let count = range.child("NumberOfOccurrences").flatMap { Int($0.trimmedText) } ?? 1
            return (.after(count), range.child("StartDate")?.trimmedText ?? "")
        }
        return (.never, recurrence.child("NoEndRecurrence")?.child("StartDate")?.trimmedText ?? "")
    }

    /// "2026-12-01", with or without a zone after it, as that day in `calendar`.
    static func day(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// How many times the series met before `day`, counting from `first`: what a series that
    /// ended after N times has left once it is cut there.
    func occurrences(from first: Date, before day: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: first)
        let stop = calendar.startOfDay(for: day)
        guard stop > start else { return 0 }
        let n = max(interval, 1)
        switch kind {
        case .daily:
            let days = calendar.dateComponents([.day], from: start, to: stop).day ?? 0
            return (days + n - 1) / n
        case .weekly:
            let wanted = Set(days(start: first, calendar: calendar))
            let firstWeek = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            var count = 0
            var cursor = start
            while cursor < stop, count < 10_000 {
                let weekStart = calendar.dateInterval(of: .weekOfYear, for: cursor)?.start ?? cursor
                let weeks = (calendar.dateComponents([.day], from: firstWeek, to: weekStart).day ?? 0) / 7
                if weeks % n == 0, wanted.contains(calendar.component(.weekday, from: cursor)) { count += 1 }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return count
        case .monthlyDay, .monthlyWeek, .yearly:
            let unit: Calendar.Component = kind == .yearly ? .year : .month
            let step = kind == .yearly ? 1 : n
            var count = 0
            while count < 10_000, let next = calendar.date(byAdding: unit, value: count * step, to: start), next < stop {
                count += 1
            }
            return count
        }
    }
}

extension EWSResponse {
    static func seriesMaster(from data: Data, calendar: Calendar = .current) throws -> SeriesMaster {
        let detail = try eventDetail(from: data)
        let root = try parse(data)
        let recurrence = root.first("Recurrence")
        let (end, start) = recurrence.map { RepeatPattern.parseEnd($0, calendar: calendar) } ?? (.never, "")
        return SeriesMaster(detail: detail, pattern: recurrence.flatMap(RepeatPattern.parse), end: end,
                            startDateText: start.isEmpty ? CalendarSOAP.dayText(detail.event.start, calendar: calendar) : start)
    }

    /// Answer ids whose subject names the meeting ("New Time Proposed: Review", "Tentative:
    /// Review"), so only those are read in full.
    static func meetingResponseIDs(from data: Data, title: String) throws -> [String] {
        let root = try parse(data)
        _ = try responseMessages(in: root)
        let needle = title.lowercased()
        return root.all("Items").flatMap(\.children).compactMap { item in
            guard let id = item.child("ItemId")?.attributes["Id"] else { return nil }
            let subject = (item.child("Subject")?.trimmedText ?? "").lowercased()
            return needle.isEmpty || subject.hasSuffix(needle) ? id : nil
        }
    }

    /// The proposals among the answers for this meeting: the newest from each person.
    static func proposals(from data: Data, eventID: String, title: String) throws -> [TimeProposal] {
        let root = try parse(data)
        var seen: Set<String> = []
        var result: [TimeProposal] = []
        for item in root.all("Items").flatMap(\.children) {
            guard let id = item.child("ItemId")?.attributes["Id"],
                  let start = item.child("ProposedStart").flatMap({ parseDate($0.trimmedText) }),
                  let end = item.child("ProposedEnd").flatMap({ parseDate($0.trimmedText) }), end > start else { continue }
            let linked = item.child("AssociatedCalendarItemId")?.attributes["Id"]
            let subject = (item.child("Subject")?.trimmedText ?? "").lowercased()
            guard linked == eventID || (!title.isEmpty && subject.hasSuffix(title.lowercased())) else { continue }
            let name = item.path("From", "Mailbox", "Name")?.trimmedText ?? ""
            let address = item.path("From", "Mailbox", "EmailAddress")?.trimmedText ?? ""
            let key = (address.isEmpty ? name : address).lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(TimeProposal(id: id, name: name, address: address, start: start, end: end))
        }
        return result
    }

    /// The iCalendar text the server wrote for an event.
    static func mimeContent(from data: Data) throws -> Data {
        let root = try parse(data)
        _ = try responseMessages(in: root)
        guard let text = root.first("MimeContent")?.trimmedText,
              let bytes = Data(base64Encoded: text, options: .ignoreUnknownCharacters), !bytes.isEmpty else {
            throw EWSError.invalidResponse("Exchange did not return the event as a file.")
        }
        return bytes
    }
}

extension EWSClient {
    func seriesMaster(occurrenceID: String, at url: URL, credential: EWSCredential) async throws -> SeriesMaster {
        try EWSResponse.seriesMaster(from: try await calendarRaw(CalendarSOAP.getMaster(occurrenceID: occurrenceID),
                                                                 url: url, credential: credential))
    }

    func deleteSeries(occurrenceID: String, cancelMeeting: Bool, at url: URL, credential: EWSCredential) async throws {
        try await calendarWrite(CalendarSOAP.deleteSeries(occurrenceID: occurrenceID, cancelMeeting: cancelMeeting),
                                url: url, credential: credential)
    }

    func endSeries(_ split: SeriesSplit, at url: URL, credential: EWSCredential) async throws {
        try await calendarWrite(CalendarSOAP.endSeries(split), url: url, credential: credential)
    }

    func moveEvent(id: String, start: Date, end: Date, notify: Bool, at url: URL, credential: EWSCredential) async throws {
        try await calendarWrite(CalendarSOAP.moveEvent(id: id, start: start, end: end, notify: notify),
                                url: url, credential: credential)
    }

    /// Proposed new times for one of the user's meetings, from the answers in the Inbox. A 2013
    /// request: older servers carry no proposed time.
    func proposals(eventID: String, title: String, at url: URL, credential: EWSCredential) async throws -> [TimeProposal] {
        let found = try await sendRaw(SOAP.envelope(.exchange2010SP2, body: CalendarSOAP.findMeetingResponses),
                                      to: url, credential: credential)
        let ids = Array(try EWSResponse.meetingResponseIDs(from: found, title: title).prefix(30))
        guard !ids.isEmpty else { return [] }
        let data = try await sendRaw(SOAP.envelope(.exchange2013, body: CalendarSOAP.getProposals(ids: ids)),
                                     to: url, credential: credential)
        return try EWSResponse.proposals(from: data, eventID: eventID, title: title)
    }

    func exportEvent(id: String, at url: URL, credential: EWSCredential) async throws -> Data {
        try EWSResponse.mimeContent(from: try await calendarRaw(CalendarSOAP.exportEvent(id: id), url: url, credential: credential))
    }
}
