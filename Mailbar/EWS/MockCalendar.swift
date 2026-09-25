import Foundation

/// The mock calendar (M15): a week shaped like the user's OWA screenshot, rebuilt around the
/// current week so it never goes stale. Every name, room and address is invented.
enum MockCalendar {
    struct Event {
        let id: String
        let subject: String
        let start: Date
        let end: Date
        var isAllDay = false
        var location = ""
        var organizer = "Sara Rahimi"
        var organizerAddress = "sara.rahimi@example.com"
        var isRecurring = false
        var isMeeting = true
        var isCancelled = false
        var response = "Accept"
        var showAs = "Busy"
        var attendees: [(String, String, String)] = []
        var notes = ""
        var categories: [String] = []
    }

    /// The mock mailbox's master category list: OWA's defaults plus a custom "Storybook", whose
    /// colour only the list can supply (its name says nothing).
    static let categoryListXML = """
    <?xml version="1.0"?><categories default="Blue category" lastSavedSession="1">\
    <category name="Blue category" color="7"/><category name="Green category" color="4"/>\
    <category name="Orange category" color="1"/><category name="Purple category" color="8"/>\
    <category name="Red category" color="0"/><category name="Storybook" color="9"/>\
    <category name="Shared team" color="-1"/>\
    <category name="Yellow category" color="3"/></categories>
    """

    static var categoryListResponse: String {
        wrap("GetUserConfiguration", """
                  <m:UserConfiguration>
                    <t:UserConfigurationName Name="CategoryList"/>
                    <t:XmlData>\(Data(categoryListXML.utf8).base64EncodedString())</t:XmlData>
                  </m:UserConfiguration>
        """)
    }

    private static func categoriesXML(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        return "<t:Categories>" + names.map { "<t:String>\(SOAP.escape($0))</t:String>" }.joined() + "</t:Categories>"
    }

    /// Three weeks around today: last week, this week, next week.
    static func events(now: Date = Date()) -> [Event] {
        var calendar = Calendar.current
        calendar.firstWeekday = 7
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        func at(_ week: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: week * 7 + day, to: thisWeek) ?? thisWeek
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        }
        func minutes(_ date: Date, _ count: Int) -> Date { date.addingTimeInterval(TimeInterval(count * 60)) }

        let room = "ساختمان نمونه | طبقه سه | اتاق آبی"
        var list: [Event] = []
        for week in -1...1 {
            // Saturday is day 0. The daily stand-up, Sunday to Wednesday, as in the screenshot.
            for day in 1...4 {
                let start = at(week, day, 11, 30)
                list.append(Event(id: "ev-\(week)-daily-\(day)", subject: "Shopping Design Daily",
                                  start: start, end: minutes(start, 30),
                                  organizer: "Mahan Rostami", organizerAddress: "mahan@example.com",
                                  isRecurring: true))
            }
        }
        let monday = 2, tuesday = 3, wednesday = 4, sunday = 1, saturday = 0, thursday = 5
        list += [
            Event(id: "ev-sat-update", subject: "BW | Design system update", start: at(0, saturday, 13),
                  end: at(0, saturday, 14), location: "CTO's Office", organizer: "Narges Ahmadi",
                  organizerAddress: "narges@example.com", isCancelled: true),
            Event(id: "ev-sun-demo", subject: "ds demo alignment", start: at(0, sunday, 18),
                  end: at(0, sunday, 19), location: room, response: "Organizer",
                  attendees: [("Omid Karimi", "omid@example.org", "Accept"), ("Sara Rahimi", "sara.rahimi@example.com", "Tentative")],
                  categories: ["Storybook"]),
            Event(id: "ev-mon-concerns", subject: "دغدغه‌های شما در مورد دیزاین‌سیستم", start: at(0, monday, 12),
                  end: at(0, monday, 13), location: room,
                  attendees: [("Omid Karimi", "omid@example.org", "Accept")],
                  notes: "<p dir=\"rtl\">لطفاً سؤال‌هایتان را از قبل در سند مشترک بنویسید.</p>"),
            Event(id: "ev-mon-worries", subject: "نگرانی‌های شما در مورد دیزاین‌سیستم", start: at(0, monday, 14),
                  end: at(0, monday, 15), location: room),
            Event(id: "ev-mon-new", subject: "New Appointment", start: at(0, monday, 15),
                  end: at(0, monday, 16), isMeeting: false, response: "Organizer"),
            Event(id: "ev-mon-workflow", subject: "Design System Workflow Demo", start: at(0, monday, 15),
                  end: minutes(at(0, monday, 16), 30), location: room, response: "NoResponseReceived",
                  showAs: "Tentative",
                  attendees: [("Sample User", "sample.user@example.com", "NoResponseReceived"), ("Omid Karimi", "omid@example.org", "Accept")],
                  notes: "<p>Walkthrough of the new token pipeline. Bring questions.</p>",
                  categories: ["Orange category"]),
            Event(id: "ev-tue-room", subject: "Room For Weekly", start: at(0, tuesday, 17),
                  end: minutes(at(0, tuesday, 18), 15), location: room, isRecurring: true, response: "Organizer",
                  categories: ["Yellow category"]),
            Event(id: "ev-tue-weekly", subject: "Design Weekly", start: at(0, tuesday, 17),
                  end: minutes(at(0, tuesday, 18), 15), location: "اتاق سبز", organizer: "Mostafa Nouri",
                  organizerAddress: "mostafa@example.com", response: "Tentative", showAs: "Tentative",
                  categories: ["Green category"]),
            Event(id: "ev-thu-core", subject: "Core Weekly", start: at(0, wednesday, 9),
                  end: at(0, wednesday, 10), location: room, isRecurring: true,
                  categories: ["Shared team"]),
            Event(id: "ev-wed-farewell", subject: "Nima's Farewell", start: at(0, wednesday, 17),
                  end: minutes(at(0, wednesday, 17), 30), organizer: "Mahan Rostami", organizerAddress: "mahan@example.com",
                  categories: ["Red category"]),
            Event(id: "ev-thu-holiday", subject: "Company holiday", start: at(0, thursday, 0),
                  end: at(0, thursday + 1, 0), isAllDay: true, isMeeting: false, response: "Organizer", showAs: "Free"),
            Event(id: "ev-next-planning", subject: "Quarterly planning", start: at(1, sunday, 10),
                  end: at(1, sunday, 12), location: room, organizer: "Omid Karimi",
                  organizerAddress: "omid@example.org", response: "NoResponseReceived", showAs: "Tentative",
                  categories: ["Purple category"]),
        ]
        return list
    }

    /// An invented company directory for the people field.
    static let directory: [(String, String)] = [
        ("Ali Tavakoli", "ali.tavakoli@example.com"), ("Amir Karimi", "amir.karimi@example.com"),
        ("Amirhossein Nadiri", "amirhossein.nadiri@example.com"), ("Narges Ahmadi", "narges@example.com"),
        ("Omid Karimi", "omid@example.org"), ("Sara Rahimi", "sara.rahimi@example.com"),
    ]

    static func resolveResponse(_ query: String) -> String {
        let matches = directory.filter { $0.0.lowercased().contains(query) || $0.1.lowercased().contains(query) }
        guard !matches.isEmpty else {
            return wrapError("ResolveNames", code: "ErrorNameResolutionNoResults")
        }
        let resolutions = matches.map { name, address in
            "<t:Resolution><t:Mailbox><t:Name>\(name)</t:Name><t:EmailAddress>\(address)</t:EmailAddress></t:Mailbox></t:Resolution>"
        }.joined()
        return wrap("ResolveNames", "<m:ResolutionSet TotalItemsInView=\"\(matches.count)\">\(resolutions)</m:ResolutionSet>")
    }

    static let roomListsResponse = wrap("GetRoomLists", """
              <m:RoomLists><t:Address><t:Name>Building A</t:Name><t:EmailAddress>rooms.a@example.com</t:EmailAddress></t:Address></m:RoomLists>
    """)

    static let roomsResponse = wrap("GetRooms", """
              <m:Rooms>
                <t:Room><t:Id><t:Name>Room Blue</t:Name><t:EmailAddress>room.blue@example.com</t:EmailAddress></t:Id></t:Room>
                <t:Room><t:Id><t:Name>Room Green</t:Name><t:EmailAddress>room.green@example.com</t:EmailAddress></t:Id></t:Room>
              </m:Rooms>
    """)

    private static func wrapError(_ operation: String, code: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:\(operation)Response xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"><m:ResponseMessages>\
        <m:\(operation)ResponseMessage ResponseClass="Error"><m:MessageText>No results.</m:MessageText>\
        <m:ResponseCode>\(code)</m:ResponseCode></m:\(operation)ResponseMessage></m:ResponseMessages>\
        </m:\(operation)Response></s:Body></s:Envelope>
        """
    }

    static func findResponse(start: Date, end: Date, events: [Event]) -> String {
        let formatter = ISO8601DateFormatter()
        let items = events.filter { $0.start < end && $0.end > start }.map { event in
            """
                      <t:CalendarItem>
                        <t:ItemId Id="\(event.id)" ChangeKey="ck"/>
                        <t:Subject>\(SOAP.escape(event.subject))</t:Subject>
                        <t:Sensitivity>Normal</t:Sensitivity>
                        \(categoriesXML(event.categories))
                        <t:ReminderIsSet>\(!event.isAllDay)</t:ReminderIsSet>
                        <t:ReminderMinutesBeforeStart>15</t:ReminderMinutesBeforeStart>
                        <t:Start>\(formatter.string(from: event.start))</t:Start>
                        <t:End>\(formatter.string(from: event.end))</t:End>
                        <t:IsAllDayEvent>\(event.isAllDay)</t:IsAllDayEvent>
                        <t:LegacyFreeBusyStatus>\(event.showAs)</t:LegacyFreeBusyStatus>
                        <t:Location>\(SOAP.escape(event.location))</t:Location>
                        <t:IsMeeting>\(event.isMeeting)</t:IsMeeting>
                        <t:IsCancelled>\(event.isCancelled)</t:IsCancelled>
                        <t:IsRecurring>\(event.isRecurring)</t:IsRecurring>
                        <t:CalendarItemType>\(event.isRecurring ? "Occurrence" : "Single")</t:CalendarItemType>
                        <t:MyResponseType>\(event.response)</t:MyResponseType>
                        <t:Organizer><t:Mailbox><t:Name>\(SOAP.escape(event.organizer))</t:Name><t:EmailAddress>\(event.organizerAddress)</t:EmailAddress></t:Mailbox></t:Organizer>
                      </t:CalendarItem>
            """
        }.joined(separator: "\n")
        return wrap("FindItem", """
                  <m:RootFolder TotalItemsInView="\(items.isEmpty ? 0 : 1)" IncludesLastItemInRange="true">
                    <t:Items>
        \(items)
                    </t:Items>
                  </m:RootFolder>
        """)
    }

    static func getResponse(_ event: Event) -> String {
        let formatter = ISO8601DateFormatter()
        let attendees = event.attendees.map { name, address, response in
            "<t:Attendee><t:Mailbox><t:Name>\(SOAP.escape(name))</t:Name><t:EmailAddress>\(address)</t:EmailAddress></t:Mailbox><t:ResponseType>\(response)</t:ResponseType></t:Attendee>"
        }.joined()
        return wrap("GetItem", """
                  <m:Items>
                    <t:CalendarItem>
                      <t:ItemId Id="\(event.id)" ChangeKey="ck"/>
                      <t:Subject>\(SOAP.escape(event.subject))</t:Subject>
                      <t:Body BodyType="HTML">\(SOAP.escape(event.notes))</t:Body>
                      \(categoriesXML(event.categories))
                      <t:Start>\(formatter.string(from: event.start))</t:Start>
                      <t:End>\(formatter.string(from: event.end))</t:End>
                      <t:IsAllDayEvent>\(event.isAllDay)</t:IsAllDayEvent>
                      <t:LegacyFreeBusyStatus>\(event.showAs)</t:LegacyFreeBusyStatus>
                      <t:Location>\(SOAP.escape(event.location))</t:Location>
                      <t:IsMeeting>\(event.isMeeting)</t:IsMeeting>
                      <t:IsCancelled>\(event.isCancelled)</t:IsCancelled>
                      <t:IsRecurring>\(event.isRecurring)</t:IsRecurring>
                      <t:MyResponseType>\(event.response)</t:MyResponseType>
                      <t:Organizer><t:Mailbox><t:Name>\(SOAP.escape(event.organizer))</t:Name><t:EmailAddress>\(event.organizerAddress)</t:EmailAddress></t:Mailbox></t:Organizer>
                      <t:RequiredAttendees>\(attendees)</t:RequiredAttendees>
                    </t:CalendarItem>
                  </m:Items>
        """)
    }

    static func wrap(_ operation: String, _ inner: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <m:\(operation)Response xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>
                <m:\(operation)ResponseMessage ResponseClass="Success">
                  <m:ResponseCode>NoError</m:ResponseCode>
        \(inner)
                </m:\(operation)ResponseMessage>
              </m:ResponseMessages>
            </m:\(operation)Response>
          </s:Body>
        </s:Envelope>
        """
    }
}
