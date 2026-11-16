import AppKit
import Foundation

/// Outlook's calendar extras (2026-11-16): which part of a series an edit or delete applies to,
/// proposals on the user's meetings, forwarding an event, mailing its attendees, and exporting it.
extension CalendarStore {

    // MARK: - Series

    /// Edit or Delete on the selected event: a repeating one asks which part first.
    func requestEdit() {
        guard let event = selectedEvent else { return }
        if event.isRecurring { askingSeries = .edit } else { startEditing() }
    }

    /// This Event edits the occurrence, as before. All Events opens the form on the series'
    /// master, its repeat rule editable. This and Following opens it on this occurrence as the
    /// start of a new series: saving ends the old one the day before (the user's pick,
    /// 2026-11-16, after Outlook; it reverses "edits apply to that occurrence only").
    func startEditing(scope: SeriesScope) async {
        askingSeries = nil
        guard scope != .occurrence else { startEditing(); return }
        guard let account, let event = selectedEvent, case .loaded(let occurrence) = detail,
              let (url, credential) = mail.connection(for: account.id) else { return }
        seriesLoading = true
        defer { seriesLoading = false }
        do {
            let master = try await mail.client.seriesMaster(occurrenceID: event.id, at: url, credential: credential)
            if scope == .following, let draft = Self.followingDraft(occurrence: occurrence, master: master,
                                                                    accountID: account.id, calendar: Calendar.current) {
                editor = draft
            } else {
                editor = Self.seriesDraft(master, accountID: account.id)
            }
        } catch {
            show(notice: describe(error))
        }
    }

    /// The form on a whole series: the master's fields and its rule, which can change.
    nonisolated static func seriesDraft(_ master: SeriesMaster, accountID: UUID) -> EventDraft {
        var draft = EventDraft.editing(master.detail, accountID: accountID)
        draft.isOccurrence = false
        draft.editsSeries = master.pattern != nil
        draft.repeatPattern = master.pattern
        draft.repeatEnd = master.end
        return draft
    }

    /// The form for This and Following: the occurrence's fields as a new series with the old
    /// one's rule, and what is left of a counted end. Nil when the occurrence is the series'
    /// first, where This and Following is the whole series.
    nonisolated static func followingDraft(occurrence: EventDetail, master: SeriesMaster, accountID: UUID,
                               calendar: Calendar) -> EventDraft? {
        guard let pattern = master.pattern else { return nil }
        let day = calendar.startOfDay(for: occurrence.event.start)
        let first = calendar.startOfDay(for: master.detail.event.start)
        guard day > first, let lastDay = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
        var draft = EventDraft.editing(occurrence, accountID: accountID)
        draft.id = nil
        draft.isOccurrence = false
        // A new series: everyone on it is invited afresh, and the files stay with the old one.
        draft.originalInvitees = []
        draft.existingFiles = []
        draft.repeatPattern = pattern
        switch master.end {
        case .after(let count):
            draft.repeatEnd = .after(max(count - pattern.occurrences(from: master.detail.event.start, before: day,
                                                                     calendar: calendar), 1))
        default:
            draft.repeatEnd = master.end
        }
        let event = master.detail.event
        draft.splitFrom = SeriesSplit(masterID: event.id, pattern: pattern, patternStart: event.start,
                                      startDateText: master.startDateText, lastDay: lastDay,
                                      notifies: event.isMeeting && event.isOrganizer && !master.detail.attendees.isEmpty)
        return draft
    }

    /// Delete on a repeating event: this occurrence, this and the ones after it (the series
    /// ends the day before), or the whole series. A meeting the user organized tells everyone.
    func deleteSelected(scope: SeriesScope) async {
        askingSeries = nil
        guard scope != .occurrence else { await deleteSelected(); return }
        guard let event = selectedEvent, canEditSelected, let account,
              let (url, credential) = mail.connection(for: account.id) else { return }
        let cancels = event.isMeeting && event.isOrganizer
        seriesLoading = true
        defer { seriesLoading = false }
        do {
            var whole = scope == .all
            if scope == .following {
                let master = try await mail.client.seriesMaster(occurrenceID: event.id, at: url, credential: credential)
                let calendar = Calendar.current
                let day = calendar.startOfDay(for: event.start)
                if let pattern = master.pattern, day > calendar.startOfDay(for: master.detail.event.start),
                   let lastDay = calendar.date(byAdding: .day, value: -1, to: day) {
                    let split = SeriesSplit(masterID: master.detail.event.id, pattern: pattern,
                                            patternStart: master.detail.event.start, startDateText: master.startDateText,
                                            lastDay: lastDay, notifies: cancels && !master.detail.attendees.isEmpty)
                    try await mail.client.endSeries(split, at: url, credential: credential)
                } else {
                    whole = true
                }
            }
            if whole {
                try await mail.client.deleteSeries(occurrenceID: event.id, cancelMeeting: cancels, at: url, credential: credential)
            }
            await select(nil)
            show(notice: cancels ? (whole ? "Series cancelled; everyone invited was told." : "Later meetings cancelled; everyone invited was told.")
                 : whole ? "Series deleted." : "This and later events deleted.")
            await refresh()
        } catch {
            show(notice: describe(error))
        }
    }

    // MARK: - Someone else's meeting

    /// Delete on an invitation: declining tells the organizer (Exchange takes a declined meeting
    /// off the calendar), deleting quietly does not.
    var canDeleteInvitation: Bool {
        guard let event = selectedEvent else { return false }
        return event.isMeeting && !event.isOrganizer
    }

    // MARK: - Proposals

    /// Reads the proposed new times for a meeting the user organized. Exchange 2013 and later
    /// only; nothing to show otherwise.
    func loadProposals(for detail: EventDetail) async {
        proposals = []
        let event = detail.event
        guard event.isMeeting, event.isOrganizer, !event.isCancelled, !detail.attendees.isEmpty,
              let account, mail.isModern(account.id),
              let (url, credential) = mail.connection(for: account.id) else { return }
        let found = (try? await mail.client.proposals(eventID: event.id, title: event.subject,
                                                       at: url, credential: credential)) ?? []
        guard selectedEventID == event.id else { return }
        proposals = found
    }

    /// Moves the meeting to the proposed time and sends everyone the update.
    func accept(_ proposal: TimeProposal) async {
        guard let event = selectedEvent, event.isOrganizer, let account,
              let (url, credential) = mail.connection(for: account.id) else { return }
        acceptingProposal = proposal.id
        defer { acceptingProposal = nil }
        do {
            try await mail.client.moveEvent(id: event.id, start: proposal.start, end: proposal.end, notify: true,
                                            at: url, credential: credential)
            show(notice: "Moved to \(proposal.display)'s time. Everyone was sent the update.")
            await refresh()
            if let fresh = events.first(where: { $0.id == event.id }) { await select(fresh) }
        } catch {
            show(notice: describe(error))
        }
    }

    // MARK: - Forward, mail the attendees, export

    /// Forward... opens Mailbar's composer on a forward of the event (`ForwardItem`).
    func forwardSelected() {
        guard let event = selectedEvent, let account else { return }
        mail.startEventForward(eventID: event.id, subject: event.subject, accountID: account.id)
    }

    /// Email Attendees: a new message to everyone invited but the user, the event's title as
    /// the subject.
    func emailAttendees() {
        guard let event = selectedEvent, let account, case .loaded(let detail) = detail else { return }
        mail.startEventEmail(to: Self.attendeeAddresses(detail, me: account.email), subject: event.subject,
                             accountID: account.id)
    }

    /// Everyone on the event, organizer first, without the user and without repeats.
    nonisolated static func attendeeAddresses(_ detail: EventDetail, me: String) -> [String] {
        var seen: Set<String> = [me.lowercased()]
        var result: [String] = []
        for address in [detail.organizerAddress] + detail.attendees.map(\.address) {
            let key = address.lowercased()
            guard !address.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(address)
        }
        return result
    }

    /// Export...: the event as the server writes it, an .ics file, saved where the user picks.
    func exportSelected() async {
        guard let event = selectedEvent, let account,
              let (url, credential) = mail.connection(for: account.id) else { return }
        do {
            let data = try await mail.client.exportEvent(id: event.id, at: url, credential: credential)
            if try Attachments.save(data, named: "\(event.subject).ics") { show(notice: "Exported.") }
        } catch {
            show(notice: describe(error))
        }
    }
}
