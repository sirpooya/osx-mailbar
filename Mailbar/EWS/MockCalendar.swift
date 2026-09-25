import AppKit
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
        var charm: Int?
        /// Attached files: id, name, size.
        var files: [(String, String, Int)] = []
        var requestsResponses = true
        var allowsForwarding = true
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

    private static func charmXML(_ charm: Int?) -> String {
        charm.map { "<t:ExtendedProperty>\(EventCharm.fieldURI)<t:Value>\($0)</t:Value></t:ExtendedProperty>" } ?? ""
    }

    private static func filesXML(_ files: [(String, String, Int)]) -> String {
        guard !files.isEmpty else { return "" }
        return "<t:Attachments>" + files.map { id, name, size in
            "<t:FileAttachment><t:AttachmentId Id=\"\(id)\"/><t:Name>\(SOAP.escape(name))</t:Name><t:ContentType>application/octet-stream</t:ContentType><t:Size>\(size)</t:Size><t:IsInline>false</t:IsInline></t:FileAttachment>"
        }.joined() + "</t:Attachments>"
    }

    /// Busy blocks for the People sidebar: Sara is busy whenever the mock calendar is, everyone
    /// else is free, and an address outside the invented domains has no data. Rooms are booked
    /// through the requested day; the detailed view adds subjects, a room's being its organizer.
    static func availabilityResponse(_ addresses: [String], events: [Event], detailed: Bool = false,
                                     windowStart: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let responses = addresses.map { address -> String in
            guard address.hasSuffix("example.com") || address.hasSuffix("example.org") else {
                return "<m:FreeBusyResponse><m:ResponseMessage ResponseClass=\"Error\"><m:ResponseCode>ErrorMailRecipientNotFound</m:ResponseCode></m:ResponseMessage></m:FreeBusyResponse>"
            }
            func block(_ start: Date, _ end: Date, _ type: String, _ subject: String, _ location: String) -> String {
                let details = detailed
                    ? "<t:CalendarEventDetails><t:Subject>\(SOAP.escape(subject))</t:Subject><t:Location>\(SOAP.escape(location))</t:Location><t:IsMeeting>true</t:IsMeeting><t:IsRecurring>false</t:IsRecurring><t:IsPrivate>false</t:IsPrivate></t:CalendarEventDetails>"
                    : ""
                return "<t:CalendarEvent><t:StartTime>\(formatter.string(from: start))</t:StartTime><t:EndTime>\(formatter.string(from: end))</t:EndTime><t:BusyType>\(type)</t:BusyType>\(details)</t:CalendarEvent>"
            }
            var blocks = (address.hasPrefix("sara") ? events.filter { !$0.isAllDay } : [])
                .map { block($0.start, $0.end, $0.showAs, $0.subject, $0.location) }
            if address.hasPrefix("room"), let windowStart, let day = formatter.date(from: String(windowStart.prefix(19))) {
                let organizers = ["Sara Rahimi", "Omid Karimi", "نرگس احمدی", "Amir Karimi"]
                let seed = address.unicodeScalars.reduce(0) { $0 + Int($1.value) }
                for slot in 0..<4 {
                    let hour = 5.5 + Double(slot) * 2.5 + Double(seed % 3) * 0.5
                    let start = day.addingTimeInterval(hour * 3600)
                    blocks.append(block(start, start.addingTimeInterval(slot == 1 ? 5400 : 3600), slot == 2 ? "Tentative" : "Busy",
                                        organizers[(seed + slot) % organizers.count], ""))
                }
            }
            return "<m:FreeBusyResponse><m:ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode></m:ResponseMessage><m:FreeBusyView><t:FreeBusyViewType>FreeBusy</t:FreeBusyViewType><t:CalendarEventArray>\(blocks.joined())</t:CalendarEventArray></m:FreeBusyView></m:FreeBusyResponse>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:GetUserAvailabilityResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">\
        <m:FreeBusyResponseArray>\(responses)</m:FreeBusyResponseArray></m:GetUserAvailabilityResponse></s:Body></s:Envelope>
        """
    }

    /// Sara and Amir have a photo (an invented one: a coloured square), everyone else has none, as a real
    /// directory mixes the two.
    static func photoResponse(for address: String) -> String {
        guard address.hasPrefix("sara") || address.hasPrefix("amir.karimi") else {
            return wrapError("GetUserPhoto", code: "ErrorItemNotFound")
        }
        let size = 96
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        if let rep, let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(srgbRed: 0.36, green: 0.55, blue: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 30, y: 46, width: 36, height: 36)).fill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: -30, width: 68, height: 70)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let png = rep?.representation(using: .png, properties: [:]) ?? Data()
        return wrap("GetUserPhoto", "<m:HasChanged>true</m:HasChanged><m:PictureData>\(png.base64EncodedString())</m:PictureData>")
    }

    static func createdResponse(id: String) -> String {
        wrap("CreateItem", "<m:Items><t:CalendarItem><t:ItemId Id=\"\(id)\" ChangeKey=\"ck\"/></t:CalendarItem></m:Items>")
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
        // Two events around the present moment, so the popover's Today strip always has one under
        // way and one coming, whatever day the sample runs on.
        let quarter = TimeInterval(15 * 60)
        let nowSlot = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / quarter).rounded(.down) * quarter)
        list += [
            Event(id: "ev-now-focus", subject: "Focus block", start: nowSlot.addingTimeInterval(-quarter),
                  end: nowSlot.addingTimeInterval(quarter * 2), isMeeting: false, response: "Organizer"),
            Event(id: "ev-now-sync", subject: "Design sync", start: nowSlot.addingTimeInterval(quarter * 3),
                  end: nowSlot.addingTimeInterval(quarter * 5), location: "Microsoft Teams Meeting",
                  notes: #"<p>Join: <a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_sample%40thread.v2/0">Click here to join the meeting</a></p>"#),
        ]
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
                  categories: ["Red category"], charm: EventCharm.cake.rawValue,
                  files: [("att-ev-card", "Farewell card.pdf", 48_213)]),
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

    /// Invented distribution groups, with their members; a group can hold a group.
    static let groups: [(name: String, address: String, members: [String])] = [
        ("Design Team", "designteam@example.com",
         ["narges@example.com", "ali.tavakoli@example.com", "sara.rahimi@example.com", "maryam.salehi@example.com",
          "design-leads@example.com"]),
        ("Design Leads", "design-leads@example.com", ["ali.tavakoli@example.com", "narges@example.com"]),
    ]

    private static func mailbox(_ name: String, _ address: String, group: Bool) -> String {
        "<t:Mailbox><t:Name>\(name)</t:Name><t:EmailAddress>\(address)</t:EmailAddress>"
            + "<t:RoutingType>SMTP</t:RoutingType><t:MailboxType>\(group ? "PublicDL" : "Mailbox")</t:MailboxType></t:Mailbox>"
    }

    /// Invented directory details for the contact card: job title, department, office, phone.
    private static let details: [String: (title: String, department: String, office: String, phone: String)] = [
        "sara.rahimi@example.com": ("UX Researcher", "Product", "Building A, floor 3", "+1 555 0101"),
        "amir.karimi@example.com": ("iOS Engineer", "Engineering", "Building A, floor 7", "+1 555 0102"),
        "omid@example.org": ("Senior Engineering Manager", "Technology", "Building B", "+1 555 0103"),
    ]

    /// With `full`, each person carries a `Contact` as `ReturnFullContactData="true"` asks.
    static func resolveResponse(_ query: String, full: Bool = false) -> String {
        let everyone = directory.map { ($0.0, $0.1, false) } + groups.map { ($0.name, $0.address, true) }
        let matches = everyone.filter { $0.0.lowercased().contains(query) || $0.1.lowercased().contains(query) }
        guard !matches.isEmpty else {
            return wrapError("ResolveNames", code: "ErrorNameResolutionNoResults")
        }
        func contact(_ name: String, _ address: String) -> String {
            guard full, let info = details[address] else { return "" }
            return "<t:Contact><t:DisplayName>\(name)</t:DisplayName><t:CompanyName>Example Co</t:CompanyName>"
                + "<t:PhysicalAddresses><t:Entry Key=\"Business\"><t:City>Springfield</t:City>"
                + "<t:CountryOrRegion>Example Land</t:CountryOrRegion></t:Entry></t:PhysicalAddresses>"
                + "<t:PhoneNumbers><t:Entry Key=\"BusinessPhone\">\(info.phone)</t:Entry></t:PhoneNumbers>"
                + "<t:Department>\(info.department)</t:Department><t:JobTitle>\(info.title)</t:JobTitle>"
                + "<t:Manager>Omid Karimi</t:Manager><t:OfficeLocation>\(info.office)</t:OfficeLocation></t:Contact>"
        }
        let resolutions = matches.map {
            "<t:Resolution>\(mailbox($0.0, $0.1, group: $0.2))\(contact($0.0, $0.1))</t:Resolution>"
        }.joined()
        return wrap("ResolveNames", "<m:ResolutionSet TotalItemsInView=\"\(matches.count)\">\(resolutions)</m:ResolutionSet>")
    }

    /// Members by name from the invented directory (and the people directory's invented
    /// people, who are not all in it), groups marked as groups.
    static func expandResponse(_ address: String) -> String {
        guard let group = groups.first(where: { $0.address == address.lowercased() }) else {
            return wrapError("ExpandDL", code: "ErrorNameResolutionNoResults")
        }
        let names = Dictionary(uniqueKeysWithValues: (directory + [("مریم صالحی", "maryam.salehi@example.com")]).map { ($0.1, $0.0) })
        let members = group.members.map { member in
            if let inner = groups.first(where: { $0.address == member }) { return mailbox(inner.name, inner.address, group: true) }
            return mailbox(names[member] ?? member, member, group: false)
        }.joined()
        return wrap("ExpandDL", """
        <m:DLExpansion TotalItemsInView="\(group.members.count)" IncludesLastItemInRange="true">\(members)</m:DLExpansion>
        """)
    }

    static let roomListsResponse = wrap("GetRoomLists", """
              <m:RoomLists><t:Address><t:Name>Building A</t:Name><t:EmailAddress>rooms.a@example.com</t:EmailAddress></t:Address></m:RoomLists>
    """)

    static let roomsResponse = wrap("GetRooms", """
              <m:Rooms>
                <t:Room><t:Id><t:Name>Room Blue</t:Name><t:EmailAddress>room.blue@example.com</t:EmailAddress></t:Id></t:Room>
                <t:Room><t:Id><t:Name>Room Green</t:Name><t:EmailAddress>room.green@example.com</t:EmailAddress></t:Id></t:Room>
                <t:Room><t:Id><t:Name>ساختمان نمونه | طبقه سه | اتاق آبی</t:Name><t:EmailAddress>room.f3.blue@example.com</t:EmailAddress></t:Id></t:Room>
                <t:Room><t:Id><t:Name>ساختمان نمونه | طبقه سه | اتاق سبز</t:Name><t:EmailAddress>room.f3.green@example.com</t:EmailAddress></t:Id></t:Room>
                <t:Room><t:Id><t:Name>ساختمان نمونه | طبقه هفت | اتاق کوچک</t:Name><t:EmailAddress>room.f7.small@example.com</t:EmailAddress></t:Id></t:Room>
                <t:Room><t:Id><t:Name>ساختمان نمونه | طبقه هفت | اتاق بزرگ</t:Name><t:EmailAddress>room.f7.large@example.com</t:EmailAddress></t:Id></t:Room>
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
                        \(charmXML(event.charm))
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
                      \(filesXML(event.files))
                      \(categoriesXML(event.categories))
                      \(charmXML(event.charm))
                      <t:ExtendedProperty>\(EventCharm.doNotForwardURI)<t:Value>\(!event.allowsForwarding)</t:Value></t:ExtendedProperty>
                      <t:Start>\(formatter.string(from: event.start))</t:Start>
                      <t:End>\(formatter.string(from: event.end))</t:End>
                      <t:IsAllDayEvent>\(event.isAllDay)</t:IsAllDayEvent>
                      <t:LegacyFreeBusyStatus>\(event.showAs)</t:LegacyFreeBusyStatus>
                      <t:Location>\(SOAP.escape(event.location))</t:Location>
                      <t:IsMeeting>\(event.isMeeting)</t:IsMeeting>
                      <t:IsCancelled>\(event.isCancelled)</t:IsCancelled>
                      <t:IsRecurring>\(event.isRecurring)</t:IsRecurring>
                      <t:IsResponseRequested>\(event.requestsResponses)</t:IsResponseRequested>
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
