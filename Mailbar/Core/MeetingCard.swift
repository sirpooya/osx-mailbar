import AppKit
import Foundation
import Observation

/// Everything the reader shows about the meeting a meeting email is for: the meeting itself,
/// the day it falls on, the organizer's photo, and the answer being given. One per open reader,
/// in memory only, gone when the reader closes, like the body.
@MainActor
@Observable
final class MeetingCard {
    let kind: MeetingMail
    let mailID: String
    let accountID: UUID
    /// The user's own address, so their row among the attendees carries their real answer.
    let myAddress: String
    @ObservationIgnored private let store: MailStore

    enum Phase: Equatable {
        case loading
        case loaded(MeetingDetails)
        /// Neither the calendar nor the email said when it is: the reader shows plain mail.
        case unavailable
    }

    var phase: Phase = .loading
    var organizerPhoto: NSImage?
    /// Each invitee's free or busy at the meeting's time, lowercased address to `Free`,
    /// `Tentative`, `Busy`, `OOF`, `WorkingElsewhere` or `NoData`. Outlook marks the invited
    /// with this, since an invitee's copy of the meeting knows no one else's answer.
    var availability: [String: String] = [:]

    /// The day the preview shows and its events, nil while they are fetched.
    var day = Calendar.current.startOfDay(for: Date())
    var dayEvents: [CalendarEvent]?
    var dayFailed = false

    /// "Add a note" was picked for this answer: the note field shows with a Send button.
    var noteFor: CalendarSOAP.Answer?
    var note = ""
    var sending: CalendarSOAP.Answer?
    /// Change was pressed on an answered invitation: the buttons come back.
    var changing = false
    var problem: String?
    /// The answer went out without telling the organizer.
    var answeredSilently = false

    /// A new time being picked in the day preview, and whether it goes as Tentative or Decline.
    var proposal: DateInterval?
    var proposeAs: CalendarSOAP.Answer = .tentative
    /// The time that was proposed, once sent.
    var proposed: DateInterval?

    /// A cancelled meeting taken off the calendar from its email.
    var removedFromCalendar = false
    var removing = false

    init(kind: MeetingMail, mailID: String, accountID: UUID, store: MailStore) {
        self.kind = kind
        self.mailID = mailID
        self.accountID = accountID
        self.store = store
        myAddress = store.accounts.account(accountID)?.email.lowercased() ?? ""
    }

    var details: MeetingDetails? {
        if case .loaded(let details) = phase { return details }
        return nil
    }

    /// The user's answer so far, or nil while it is still open.
    var myAnswer: CalendarSOAP.Answer? {
        CalendarSOAP.Answer.allCases.first { $0.responseType == details?.event.myResponse }
    }

    var isOrganizer: Bool { details?.event.isOrganizer == true }

    /// The buttons show: an open invitation, or Change was pressed.
    var showsAnswerButtons: Bool { myAnswer == nil || changing }

    /// Required, then optional, the organizer left out (the From line names them); the user's
    /// own row carries the answer the calendar holds for them, since an attendee's copy of the
    /// list does not know it.
    func attendees(optional: Bool) -> [EventDetail.Attendee] {
        guard let details else { return [] }
        let organizer = details.organizerAddress.lowercased()
        return details.attendees.filter { $0.isOptional == optional && ($0.address.lowercased() != organizer || organizer.isEmpty) }
            .map { attendee in
                guard !myAddress.isEmpty, attendee.address.lowercased() == myAddress,
                      !["Organizer", "Unknown"].contains(details.event.myResponse) else { return attendee }
                return EventDetail.Attendee(name: attendee.name, address: attendee.address,
                                            response: details.event.myResponse, isOptional: attendee.isOptional)
            }
    }

    /// The meeting link in the calendar copy's notes, the email's body or the location.
    func joinLink(bodyHTML: String) -> URL? {
        guard let details else { return nil }
        return TodayAgenda.joinLink(inHTML: details.notesHTML + " " + bodyHTML + " " + details.event.location)
    }

    // MARK: - Loading

    func load(senderAddress: String) async {
        guard let (url, credential) = store.connection(for: accountID) else {
            phase = .unavailable
            return
        }
        do {
            let details = try await store.client.meetingDetails(mailID: mailID, kind: kind,
                                                                 modern: store.isModern(accountID),
                                                                 at: url, credential: credential)
            guard !Task.isCancelled else { return }
            phase = .loaded(details)
            day = Calendar.current.startOfDay(for: details.event.start)
            if kind == .request {
                await loadDay()
                await loadAvailability(details)
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .unavailable
        }
        if !senderAddress.isEmpty, !Task.isCancelled {
            organizerPhoto = await store.photo(for: senderAddress, accountID: accountID)
        }
    }

    /// Free or busy for everyone invited, the meeting itself left out: its own hold (tentative
    /// on every invitee's calendar until they answer) would otherwise mark them all tentative.
    private func loadAvailability(_ details: MeetingDetails) async {
        let addresses = details.attendees.map(\.address).filter { !$0.isEmpty }
        guard !addresses.isEmpty, let (url, credential) = store.connection(for: accountID),
              let blocks = try? await store.client.busyBlocks(addresses, start: details.event.start, end: details.event.end,
                                                               at: url, credential: credential) else { return }
        availability = Self.states(blocks, during: details.event)
    }

    nonisolated static func states(_ blocks: [String: [BusyBlock]?], during meeting: CalendarEvent) -> [String: String] {
        let rank = ["Free": 0, "WorkingElsewhere": 1, "Tentative": 2, "Busy": 3, "OOF": 4]
        var result: [String: String] = [:]
        for (address, list) in blocks {
            guard let list else { result[address] = "NoData"; continue }
            var state = "Free"
            for block in list where block.start < meeting.end && block.end > meeting.start
                && !(block.start == meeting.start && block.end == meeting.end) {
                if (rank[block.type] ?? 0) > (rank[state] ?? 0) { state = block.type }
            }
            result[address] = state
        }
        return result
    }

    /// What a person's dot says: their answer when the server knows it (the organizer's copy
    /// does), else whether they are free at that time.
    func status(of attendee: EventDetail.Attendee) -> MeetingStatus {
        switch attendee.response {
        case "Accept": return .accepted
        case "Tentative": return .tentative
        case "Decline": return .declined
        default: break
        }
        switch availability[attendee.address.lowercased()] {
        case "Free": return .free
        case "Tentative": return .tentativeTime
        case "Busy": return .busy
        case "OOF": return .away
        case "WorkingElsewhere": return .elsewhere
        case "NoData": return .noInformation
        default: return kind == .request ? .noInformation : .noAnswer
        }
    }

    /// The events of the day on show. An answer for a day since left is dropped.
    func loadDay() async {
        let calendar = Calendar.current
        let wanted = day
        guard let end = calendar.date(byAdding: .day, value: 1, to: wanted),
              let (url, credential) = store.connection(for: accountID) else { return }
        dayEvents = nil
        dayFailed = false
        do {
            let events = try await store.client.calendarEvents(from: wanted, to: end, at: url, credential: credential)
            guard wanted == day else { return }
            dayEvents = TodayAgenda.all(of: events, on: wanted)
        } catch {
            guard wanted == day else { return }
            dayFailed = true
        }
    }

    /// The day's events with the meeting itself drawn once: the calendar's copy of a repeating
    /// meeting is its series, whose occurrences have ids of their own, so a match on title and
    /// start counts as the same event.
    func previewEvents() -> (others: [CalendarEvent], meeting: CalendarEvent?) {
        guard let details else { return (dayEvents ?? [], nil) }
        let meeting = details.event
        let others = (dayEvents ?? []).filter { event in
            event.id != details.calendarItemID && event.id != meeting.id
                && !(event.subject == meeting.subject && event.start == meeting.start)
        }
        let onDay = Calendar.current.isDate(meeting.start, inSameDayAs: day)
            || (meeting.start < day && meeting.end > day)
        return (others, onDay ? meeting : nil)
    }

    // MARK: - Answering

    /// Sends the answer. The first answer goes to the email, as Outlook's does; a changed one to
    /// the calendar's event, since Exchange may have moved the email once it was answered.
    func answer(_ answer: CalendarSOAP.Answer, send: Bool = true) async {
        guard sending == nil else { return }
        sending = answer
        problem = nil
        defer { sending = nil }
        let reference = myAnswer != nil ? details?.calendarItemID : nil
        let proposal = answer == .accept ? nil : self.proposal
        do {
            try await store.answerInvitation(answer, message: mailID, reference: reference, in: accountID,
                                             note: note, send: send, proposal: proposal)
            if case .loaded(var details) = phase {
                details.event.myResponse = answer.responseType
                details.event.showAs = answer == .accept ? "Busy" : answer == .tentative ? "Tentative" : "Free"
                phase = .loaded(details)
            }
            answeredSilently = !send
            proposed = proposal
            self.proposal = nil
            noteFor = nil
            note = ""
            changing = false
            CalendarWindow.shared.refreshIfOpen()
            if kind == .request { await loadDay() }
        } catch let error as EWSError {
            problem = error.message(host: store.accounts.account(accountID)?.host ?? "The server")
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Proposing a new time

    /// Needs Exchange 2013 or later: older servers have no proposed time on an answer.
    var canPropose: Bool { store.isModern(accountID) }

    func startProposing(as answer: CalendarSOAP.Answer) {
        guard let meeting = details?.event else { return }
        proposeAs = answer
        noteFor = nil
        let calendar = Calendar.current
        if !calendar.isDate(meeting.start, inSameDayAs: day) {
            day = calendar.startOfDay(for: meeting.start)
            Task { await loadDay() }
        }
        proposal = DateInterval(start: meeting.start, end: max(meeting.end, meeting.start.addingTimeInterval(15 * 60)))
    }

    func cancelProposing() {
        proposal = nil
        guard let meeting = details?.event, !Calendar.current.isDate(meeting.start, inSameDayAs: day) else { return }
        day = Calendar.current.startOfDay(for: meeting.start)
        Task { await loadDay() }
    }

    /// Moves the proposed time to start at `start`, in 15-minute steps, its length kept and the
    /// whole of it inside the day on show.
    func moveProposal(to start: Date) {
        guard let proposal else { return }
        let quarter: TimeInterval = 15 * 60
        let dayStart = day
        let latest = dayStart.addingTimeInterval(24 * 3600 - proposal.duration)
        let offset = (start.timeIntervalSince(dayStart) / quarter).rounded() * quarter
        let snapped = min(max(dayStart.addingTimeInterval(offset), dayStart), max(latest, dayStart))
        self.proposal = DateInterval(start: snapped, duration: proposal.duration)
    }

    /// Another day for the preview; while proposing, the proposed time moves with it.
    func showDay(offset: Int) async {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .day, value: offset, to: day) else { return }
        if let proposal, let start = calendar.date(byAdding: .day, value: offset, to: proposal.start) {
            self.proposal = DateInterval(start: start, duration: proposal.duration)
        }
        day = next
        await loadDay()
    }

    func sendProposal() async {
        await answer(proposeAs)
    }

    // MARK: - Cancellations

    func removeFromCalendar() async {
        removing = true
        problem = nil
        defer { removing = false }
        do {
            try await store.removeCancelledMeeting(message: mailID, in: accountID)
            removedFromCalendar = true
            CalendarWindow.shared.refreshIfOpen()
        } catch let error as EWSError {
            problem = error.message(host: store.accounts.account(accountID)?.host ?? "The server")
        } catch {
            problem = error.localizedDescription
        }
    }

    /// True when the HTML holds no text and no image: an invitation sent without a description.
    /// The day preview then takes the whole body.
    nonisolated static func isBlank(_ html: String) -> Bool {
        if html.range(of: "<img", options: .caseInsensitive) != nil { return false }
        var text = html
        for pattern in [#"<style[\s\S]*?</style>"#, #"<head[\s\S]*?</head>"#, "<[^>]+>", "&nbsp;|&#160;"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty
    }
}

extension CalendarSOAP.Answer {
    /// Outlook's marks on its answer buttons.
    var symbol: String {
        switch self {
        case .accept: return "checkmark"
        case .tentative: return "questionmark"
        case .decline: return "xmark"
        }
    }

    /// "You accepted", for the line that replaces the buttons.
    var pastTense: String {
        switch self {
        case .accept: return "accepted"
        case .tentative: return "tentatively accepted"
        case .decline: return "declined"
        }
    }
}

/// One invitee's dot.
enum MeetingStatus {
    case accepted, tentative, declined, noAnswer
    case free, tentativeTime, busy, away, elsewhere, noInformation

    var label: String {
        switch self {
        case .accepted: return "Accepted"
        case .tentative: return "Tentatively accepted"
        case .declined: return "Declined"
        case .noAnswer: return "No answer yet"
        case .free: return "Free at this time"
        case .tentativeTime: return "Tentative at this time"
        case .busy: return "Busy at this time"
        case .away: return "Away at this time"
        case .elsewhere: return "Working elsewhere at this time"
        case .noInformation: return "No free/busy information"
        }
    }
}
