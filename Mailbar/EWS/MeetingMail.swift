import Foundation

/// The meeting a meeting email is about, for the reader's card: when and where, who is invited
/// and how they answered, and the user's own answer. In memory while the reader is open.
struct MeetingDetails: Equatable, Sendable {
    /// The calendar's own copy of the event when there is one (its answer, category and
    /// attendees' answers are the true ones), else the email's own fields.
    var event: CalendarEvent
    var organizerAddress: String
    var attendees: [EventDetail.Attendee]
    var rooms: [String]
    /// The event on the user's calendar, or nil when the calendar holds none (a cancelled
    /// meeting already removed, or a server that has not placed the invitation yet).
    var calendarItemID: String?
    /// The notes of the calendar copy, where the meeting link usually is.
    var notesHTML: String
    /// A new time an attendee proposed, on their answer (Exchange 2013 and later).
    var proposal: DateInterval?

    init(_ detail: EventDetail, calendarItemID: String?) {
        event = detail.event
        organizerAddress = detail.organizerAddress
        attendees = detail.attendees
        rooms = detail.rooms
        self.calendarItemID = calendarItemID
        notesHTML = detail.html
    }
}

extension SOAP {
    /// The link from a meeting email to its event on the calendar. Every meeting email type has
    /// it (Exchange 2007 on), so this one request is safe whatever the item is.
    static func getMeetingLink(id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
                  <t:FieldURI FieldURI="meeting:AssociatedCalendarItemId"/>
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    /// The meeting's own fields on the email, for when the calendar has no copy. An invitation
    /// carries the whole event; a cancellation or an answer only its time and place, and only
    /// from Exchange 2013 on.
    static func getMeetingFields(id: String, invitation: Bool) -> String {
        let fields = invitation
            ? ["item:Subject", "calendar:Start", "calendar:End", "calendar:IsAllDayEvent", "calendar:Location",
               "calendar:Organizer", "calendar:IsRecurring", "calendar:IsMeeting", "calendar:IsCancelled",
               "calendar:LegacyFreeBusyStatus", "calendar:CalendarItemType", "calendar:RequiredAttendees",
               "calendar:OptionalAttendees", "calendar:Resources"]
            : ["item:Subject", "calendar:Start", "calendar:End", "calendar:Location"]
        return """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
        \(fields.map { "          <t:FieldURI FieldURI=\"\($0)\"/>" }.joined(separator: "\n"))
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }

    /// The new time an attendee proposed on their answer. Exchange 2013 and later.
    static func getProposedTime(id: String) -> String {
        """
            <m:GetItem>
              <m:ItemShape>
                <t:BaseShape>IdOnly</t:BaseShape>
                <t:AdditionalProperties>
                  <t:FieldURI FieldURI="meetingResponse:ProposedStart"/>
                  <t:FieldURI FieldURI="meetingResponse:ProposedEnd"/>
                </t:AdditionalProperties>
              </m:ItemShape>
              <m:ItemIds><t:ItemId Id="\(escape(id))"/></m:ItemIds>
            </m:GetItem>
        """
    }
}

extension EWSResponse {
    /// The calendar event a meeting email points at, or nil when it points nowhere.
    static func associatedCalendarItemID(from data: Data) throws -> String? {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        return responses.first?.first("AssociatedCalendarItemId")?.attributes["Id"]
    }

    static func proposedTime(from data: Data) throws -> DateInterval? {
        let root = try parse(data)
        let responses = try responseMessages(in: root)
        guard let item = responses.first?.child("Items")?.children.first,
              let start = item.child("ProposedStart").flatMap({ parseDate($0.trimmedText) }),
              let end = item.child("ProposedEnd").flatMap({ parseDate($0.trimmedText) }),
              end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}

extension EWSClient {
    /// The calendar's copy when the email links to one, else the email's own fields. Throws only
    /// when neither can be read; the reader then shows the email as plain mail.
    func meetingDetails(mailID: String, kind: MeetingMail, modern: Bool,
                        at url: URL, credential: EWSCredential) async throws -> MeetingDetails {
        let link = try EWSResponse.associatedCalendarItemID(
            from: try await sendRaw(SOAP.envelope(.exchange2010SP2, body: SOAP.getMeetingLink(id: mailID)),
                                    to: url, credential: credential))
        var details: MeetingDetails
        if let link, let detail = try? await eventDetail(id: link, at: url, credential: credential) {
            details = MeetingDetails(detail, calendarItemID: link)
        } else {
            let invitation = kind == .request
            guard invitation || modern else { throw EWSError.invalidResponse("The meeting's time is not on this email.") }
            let data = try await sendRaw(SOAP.envelope(modern ? .exchange2013 : .exchange2010SP2,
                                                       body: SOAP.getMeetingFields(id: mailID, invitation: invitation)),
                                         to: url, credential: credential)
            details = MeetingDetails(try EWSResponse.eventDetail(from: data), calendarItemID: nil)
        }
        if case .response = kind, modern {
            let data = try? await sendRaw(SOAP.envelope(.exchange2013, body: SOAP.getProposedTime(id: mailID)),
                                          to: url, credential: credential)
            details.proposal = data.flatMap { try? EWSResponse.proposedTime(from: $0) }
        }
        return details
    }
}
