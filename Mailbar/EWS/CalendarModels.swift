import Foundation

/// One calendar event as the grid draws it (M15). In memory only, for the range on screen.
struct CalendarEvent: Identifiable, Equatable, Sendable {
    /// EWS `ItemId`. For a recurring series each occurrence has its own id.
    let id: String
    let changeKey: String
    let subject: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String
    let organizer: String
    let isRecurring: Bool
    let isMeeting: Bool
    let isCancelled: Bool
    /// `Organizer`, `Accept`, `Tentative`, `Decline`, `NoResponseReceived`, `Unknown`.
    let myResponse: String
    /// `Free`, `Tentative`, `Busy`, `OOF`, `WorkingElsewhere`, `NoData`.
    let showAs: String
    let isPrivate: Bool
    /// Category names, as the user set them in Outlook or OWA. Their colours come from
    /// `CategoryColors` and the mailbox's master list.
    var categories: [String] = []
    /// Minutes before the start, or nil when no reminder is set (M18).
    var reminderMinutes: Int? = nil
    /// OWA's charm, the small icon beside the title (`EventCharm`), or nil for none.
    var charm: Int? = nil

    /// Not yet answered or only tentatively: OWA draws these hatched, and so does the grid.
    var isTentative: Bool {
        myResponse == "Tentative" || myResponse == "NoResponseReceived" || showAs == "Tentative"
    }

    var isOrganizer: Bool { myResponse == "Organizer" }

    /// The days this event touches, as start-of-day dates in `calendar`. An all-day event's end
    /// is the midnight after its last day, so that midnight is not a day of its own.
    func days(in calendar: Calendar) -> [Date] {
        let first = calendar.startOfDay(for: start)
        let lastMoment = max(start, end.addingTimeInterval(-1))
        let last = calendar.startOfDay(for: lastMoment)
        var days: [Date] = []
        var day = first
        while day <= last {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
}

/// Everything the detail panel shows for one event.
struct EventDetail: Equatable, Sendable {
    struct Attendee: Equatable, Sendable, Identifiable {
        let name: String
        let address: String
        /// `Accept`, `Tentative`, `Decline`, `NoResponseReceived`, `Organizer`, `Unknown`.
        let response: String
        let isOptional: Bool
        var id: String { address.isEmpty ? name : address }
        var display: String { name.isEmpty ? address : name }
    }

    let event: CalendarEvent
    let organizerAddress: String
    let attendees: [Attendee]
    let rooms: [String]
    let html: String
    /// Minutes before the start, or nil when no reminder is set.
    var reminderMinutes: Int? = nil
    /// The rooms with their addresses, for editing the booking.
    var roomBoxes: [Room] = []
    /// Files attached to the event. Bytes are fetched only when one is opened or saved.
    var files: [FileAttachment] = []
    /// OWA's Response options: whether answers are asked for, and whether the invitation may
    /// be forwarded.
    var requestsResponses = true
    var allowsForwarding = true
}

extension EWSResponse {
    static func calendarEvents(from data: Data) throws -> [CalendarEvent] {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        guard let items = responses.first?.first("Items") else {
            throw EWSError.invalidResponse("The reply did not include the calendar.")
        }
        return items.children.compactMap(calendarEvent(from:))
    }

    static func calendarEvent(from item: XMLTreeNode) -> CalendarEvent? {
        guard let itemID = item.child("ItemId"), let id = itemID.attributes["Id"],
              let start = item.child("Start").flatMap({ parseDate($0.trimmedText) }),
              let end = item.child("End").flatMap({ parseDate($0.trimmedText) }) else { return nil }
        let subject = item.child("Subject")?.trimmedText ?? ""
        return CalendarEvent(
            id: id,
            changeKey: itemID.attributes["ChangeKey"] ?? "",
            subject: subject.isEmpty ? "(No title)" : subject,
            start: start,
            end: max(end, start),
            isAllDay: item.child("IsAllDayEvent")?.trimmedText == "true",
            location: item.child("Location")?.trimmedText ?? "",
            organizer: item.path("Organizer", "Mailbox", "Name")?.trimmedText ?? "",
            isRecurring: item.child("IsRecurring")?.trimmedText == "true"
                || ["Occurrence", "Exception"].contains(item.child("CalendarItemType")?.trimmedText ?? ""),
            isMeeting: item.child("IsMeeting")?.trimmedText == "true",
            isCancelled: item.child("IsCancelled")?.trimmedText == "true",
            myResponse: item.child("MyResponseType")?.trimmedText ?? "Unknown",
            showAs: item.child("LegacyFreeBusyStatus")?.trimmedText ?? "Busy",
            isPrivate: item.child("Sensitivity")?.trimmedText == "Private",
            categories: (item.child("Categories")?.children ?? []).map(\.trimmedText).filter { !$0.isEmpty },
            reminderMinutes: item.child("ReminderIsSet")?.trimmedText == "true"
                ? (item.child("ReminderMinutesBeforeStart").flatMap { Int($0.trimmedText) } ?? 15) : nil,
            charm: charm(in: item))
    }

    /// The charm's extended property, when the event has one OWA knows.
    static func charm(in item: XMLTreeNode) -> Int? {
        for property in item.children where property.name == "ExtendedProperty" {
            guard let uri = property.child("ExtendedFieldURI"),
                  uri.attributes["PropertySetId"]?.uppercased() == EventCharm.propertySetID,
                  uri.attributes["PropertyId"].flatMap({ Int($0) }) == EventCharm.propertyID,
                  let value = property.child("Value").flatMap({ Int($0.trimmedText) }),
                  EventCharm(rawValue: value) != nil else { continue }
            return value
        }
        return nil
    }

    static func eventDetail(from data: Data) throws -> EventDetail {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        guard let item = responses.first?.child("Items")?.children.first,
              let event = calendarEvent(from: item) else {
            throw EWSError.invalidResponse("The reply did not include the event.")
        }
        func attendees(_ field: String, optional: Bool) -> [EventDetail.Attendee] {
            (item.child(field)?.children ?? []).filter { $0.name == "Attendee" }.map { attendee in
                EventDetail.Attendee(name: attendee.path("Mailbox", "Name")?.trimmedText ?? "",
                                     address: attendee.path("Mailbox", "EmailAddress")?.trimmedText ?? "",
                                     response: attendee.child("ResponseType")?.trimmedText ?? "Unknown",
                                     isOptional: optional)
            }
        }
        let rooms = (item.child("Resources")?.children ?? []).compactMap { $0.path("Mailbox", "Name")?.trimmedText }
        let roomBoxes: [Room] = (item.child("Resources")?.children ?? []).compactMap { attendee in
            guard let address = attendee.path("Mailbox", "EmailAddress")?.trimmedText, !address.isEmpty else { return nil }
            return Room(name: attendee.path("Mailbox", "Name")?.trimmedText ?? address, address: address)
        }
        let reminderSet = item.child("ReminderIsSet")?.trimmedText == "true"
        let reminder = item.child("ReminderMinutesBeforeStart").flatMap { Int($0.trimmedText) }
        return EventDetail(event: event,
                           organizerAddress: item.path("Organizer", "Mailbox", "EmailAddress")?.trimmedText ?? "",
                           attendees: attendees("RequiredAttendees", optional: false)
                               + attendees("OptionalAttendees", optional: true),
                           rooms: rooms,
                           html: item.child("Body")?.text ?? "",
                           reminderMinutes: reminderSet ? (reminder ?? 15) : nil,
                           roomBoxes: roomBoxes,
                           files: (item.child("Attachments")?.children ?? []).compactMap { attachment in
                               guard attachment.name == "FileAttachment",
                                     attachment.child("IsInline")?.trimmedText != "true",
                                     let id = attachment.child("AttachmentId")?.attributes["Id"] else { return nil }
                               return FileAttachment(id: id,
                                                     name: attachment.child("Name").map(\.trimmedText).flatMap { $0.isEmpty ? nil : $0 } ?? "Attachment",
                                                     contentType: attachment.child("ContentType")?.trimmedText ?? "",
                                                     size: attachment.child("Size").flatMap { Int($0.trimmedText) } ?? 0)
                           },
                           requestsResponses: item.child("IsResponseRequested")?.trimmedText != "false",
                           allowsForwarding: !item.children.contains { property in
                               property.name == "ExtendedProperty"
                                   && property.child("ExtendedFieldURI")?.attributes["PropertyName"] == "DoNotForward"
                                   && property.child("Value")?.trimmedText == "true"
                           })
    }
}
