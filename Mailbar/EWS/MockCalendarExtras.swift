import Foundation

/// The mock server's answers for the calendar extras (2026-11-16): a series' master, deleting a
/// whole series, attendees' proposed times on "ds demo alignment", and an event as an .ics file.
/// Every name and address is invented.
extension MockCalendar {
    /// Nil when the request is not one of these, so the main mock answers it.
    static func extraResponse(to request: String, events: [Event]) -> String? {
        func match(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let found = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)),
                  let range = Range(found.range(at: 1), in: request) else { return nil }
            return String(request[range])
        }
        let occurrence = match(#"RecurringMasterItemId OccurrenceId="([^"]+)""#)
        if request.contains("<m:GetItem>"), let occurrence,
           let event = events.first(where: { $0.id == occurrence }) {
            return masterResponse(for: event)
        }
        if request.contains("<m:DeleteItem"), occurrence != nil {
            return wrap("DeleteItem", "")
        }
        if request.contains("<m:FindItem"), request.contains("IPM.Schedule.Meeting.Resp") {
            return wrap("FindItem", """
                      <m:RootFolder TotalItemsInView="2" IncludesLastItemInRange="true"><t:Items>
                        <t:MeetingResponse><t:ItemId Id="resp-omid" ChangeKey="ck"/><t:Subject>New Time Proposed: ds demo alignment</t:Subject><t:ItemClass>IPM.Schedule.Meeting.Resp.Tent</t:ItemClass></t:MeetingResponse>
                        <t:MeetingResponse><t:ItemId Id="resp-sara" ChangeKey="ck"/><t:Subject>Declined: ds demo alignment</t:Subject><t:ItemClass>IPM.Schedule.Meeting.Resp.Neg</t:ItemClass></t:MeetingResponse>
                        <t:MeetingResponse><t:ItemId Id="resp-other" ChangeKey="ck"/><t:Subject>Accepted: Quarterly planning</t:Subject><t:ItemClass>IPM.Schedule.Meeting.Resp.Pos</t:ItemClass></t:MeetingResponse>
                      </t:Items></m:RootFolder>
            """)
        }
        if request.contains("<m:GetItem>"), request.contains("meetingResponse:ProposedStart"), request.contains("resp-"),
           let demo = events.first(where: { $0.id == "ev-sun-demo" }) {
            let formatter = ISO8601DateFormatter()
            let day = 86_400.0
            func response(_ id: String, _ name: String, _ address: String, _ offset: TimeInterval, _ hours: TimeInterval) -> String {
                let start = demo.start.addingTimeInterval(offset)
                return """
                <t:MeetingResponse><t:ItemId Id="\(id)" ChangeKey="ck"/><t:Subject>New Time Proposed: ds demo alignment</t:Subject>\
                <t:From><t:Mailbox><t:Name>\(name)</t:Name><t:EmailAddress>\(address)</t:EmailAddress></t:Mailbox></t:From>\
                <t:AssociatedCalendarItemId Id="\(demo.id)" ChangeKey="ck"/>\
                <t:ProposedStart>\(formatter.string(from: start))</t:ProposedStart>\
                <t:ProposedEnd>\(formatter.string(from: start.addingTimeInterval(hours * 3600)))</t:ProposedEnd></t:MeetingResponse>
                """
            }
            var items: [String] = []
            if request.contains("resp-omid") { items.append(response("resp-omid", "Omid Karimi", "omid@example.org", day - 8 * 3600, 1)) }
            if request.contains("resp-sara") { items.append(response("resp-sara", "Sara Rahimi", "sara.rahimi@example.com", 2 * day - 4 * 3600, 1)) }
            return wrap("GetItem", "<m:Items>\(items.joined())</m:Items>")
        }
        if request.contains("<t:IncludeMimeContent>true</t:IncludeMimeContent>"),
           let id = match(#"ItemId Id="(ev-[^"]+)""#), let event = events.first(where: { $0.id == id }) {
            return wrap("GetItem", """
                      <m:Items><t:CalendarItem><t:ItemId Id="\(event.id)" ChangeKey="ck"/>\
                      <t:MimeContent CharacterSet="UTF-8">\(Data(ics(for: event).utf8).base64EncodedString())</t:MimeContent>\
                      </t:CalendarItem></m:Items>
            """)
        }
        return nil
    }

    /// A weekly series that began four weeks before this occurrence, never ending.
    static func masterResponse(for event: Event) -> String {
        let start = event.start.addingTimeInterval(-28 * 86_400)
        let master = Event(id: "ev-master-\(event.id)", subject: event.subject, start: start,
                       end: start.addingTimeInterval(event.end.timeIntervalSince(event.start)),
                       isAllDay: event.isAllDay, location: event.location, organizer: event.organizer,
                       organizerAddress: event.organizerAddress, isRecurring: false, isMeeting: event.isMeeting,
                       isCancelled: false, response: event.response, showAs: event.showAs, attendees: event.attendees,
                       notes: event.notes, categories: event.categories, charm: event.charm)
        let weekday = RepeatPattern.dayNames[Calendar.current.component(.weekday, from: start) - 1]
        let recurrence = "<t:CalendarItemType>RecurringMaster</t:CalendarItemType><t:Recurrence><t:WeeklyRecurrence><t:Interval>1</t:Interval>"
            + "<t:DaysOfWeek>\(weekday)</t:DaysOfWeek></t:WeeklyRecurrence><t:NoEndRecurrence><t:StartDate>"
            + CalendarSOAP.dayText(start) + "</t:StartDate></t:NoEndRecurrence></t:Recurrence>"
        return getResponse(master).replacingOccurrences(of: "</t:CalendarItem>", with: recurrence + "</t:CalendarItem>")
    }

    /// The event as Exchange's MimeContent writes it, near enough.
    static func ics(for event: Event) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return [
            "BEGIN:VCALENDAR", "PRODID:-//Mailbar mock//EN", "VERSION:2.0", "METHOD:PUBLISH", "BEGIN:VEVENT",
            "UID:\(event.id)@example.com", "SUMMARY:\(event.subject)", "LOCATION:\(event.location)",
            "DTSTART:\(formatter.string(from: event.start))", "DTEND:\(formatter.string(from: event.end))",
            "ORGANIZER;CN=\(event.organizer):mailto:\(event.organizerAddress)", "END:VEVENT", "END:VCALENDAR", "",
        ].joined(separator: "\r\n")
    }

    /// A sample invitation file, for the Add to Calendar screenshot: a Tehran-time workshop and
    /// an all-day offsite that repeats.
    static let sampleICS = """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Example Corp//Events//EN\r
    BEGIN:VEVENT\r
    UID:workshop-1@example.com\r
    SUMMARY:Accessibility workshop\r
    LOCATION:Example Hall\\, Room 2\r
    DESCRIPTION:Bring a laptop.\\nSlides are shared after.\r
    DTSTART;TZID=Asia/Tehran:20261124T100000\r
    DTEND;TZID=Asia/Tehran:20261124T120000\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:offsite-1@example.com\r
    SUMMARY:Team offsite\r
    DTSTART;VALUE=DATE:20261203\r
    DTEND;VALUE=DATE:20261204\r
    RRULE:FREQ=MONTHLY;COUNT=3\r
    END:VEVENT\r
    END:VCALENDAR\r

    """
}
