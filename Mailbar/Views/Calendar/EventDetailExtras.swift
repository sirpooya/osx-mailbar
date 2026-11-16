import SwiftUI

/// Outlook's question on a repeating event (2026-11-16): which part an edit or delete applies to.
/// Inline in the panel, as the delete confirmation is, not a sheet over the window.
struct SeriesChoiceBox: View {
    @Bindable var store: CalendarStore
    let action: CalendarStore.SeriesAction
    let event: CalendarEvent

    var body: some View {
        let deleting = action == .delete
        let cancels = deleting && event.isMeeting && event.isOrganizer
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(deleting ? (cancels ? "Cancel a repeating meeting" : "Delete a repeating event") : "Edit a repeating event")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                if store.seriesLoading { ProgressView().controlSize(.mini) }
                Button(deleting ? "Keep" : "Cancel") { store.askingSeries = nil }
                    .keyboardShortcut(.cancelAction)
            }
            if cancels {
                Text("Everyone invited is told.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(SeriesScope.allCases) { scope in
                    Button(scope.label) {
                        Task {
                            if deleting { await store.deleteSelected(scope: scope) } else { await store.startEditing(scope: scope) }
                        }
                    }
                }
            }
            .disabled(store.seriesLoading)
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(deleting ? Color.red.opacity(0.07) : Color.primary.opacity(0.05)))
        .padding(.horizontal, EventDetailPanel.inset)
        .padding(.bottom, 12)
    }
}

/// Delete on someone else's meeting, after Outlook: decline it, which tells the organizer and
/// takes it off the calendar, or delete it without a word (`SendMeetingCancellations` none).
struct InviteeDeleteBox: View {
    @Bindable var store: CalendarStore
    let event: CalendarEvent
    @State private var working = false

    var body: some View {
        let organizer = event.organizer.isEmpty ? "the organizer" : event.organizer
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete this meeting?").font(.system(size: 12, weight: .medium))
            Button {
                run { await store.answerSelected(.decline, note: "") }
            } label: {
                Text("Delete and Notify Organizer (Decline)").frame(maxWidth: .infinity)
            }
            .help("Declines, so \(organizer) knows you will not come")
            Button {
                run { await store.deleteSelected(quietly: true) }
            } label: {
                Text("Delete Without Notifying").frame(maxWidth: .infinity)
            }
            .help("Moves it to Deleted Items; \(organizer) is not told")
            HStack {
                if working { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Button("Keep") { store.askingInviteeDelete = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .disabled(working)
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.07)))
        .padding(.horizontal, EventDetailPanel.inset)
        .padding(.bottom, 12)
    }

    private func run(_ work: @escaping () async -> Void) {
        working = true
        Task {
            await work()
            working = false
            store.askingInviteeDelete = false
        }
    }
}

/// The times attendees proposed for the user's meeting, each with Accept Proposal, which moves
/// the meeting there and sends everyone the update.
struct ProposalList: View {
    @Bindable var store: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.proposals.count == 1 ? "1 new time proposed" : "\(store.proposals.count) new times proposed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(store.proposals) { proposal in
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        DirectionalText(proposal.display, font: .system(size: 12), pinnedLeading: true)
                        Text(Self.when(proposal))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if store.acceptingProposal == proposal.id {
                        ProgressView().controlSize(.mini)
                    }
                    Button("Accept Proposal") { Task { await store.accept(proposal) } }
                        .controlSize(.small)
                        .disabled(store.acceptingProposal != nil)
                        .help("Move the meeting to this time and send everyone the update")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Mon, Nov 16, 10:00 to 11:00", short enough beside the button.
    static func when(_ proposal: TimeProposal) -> String {
        let day = proposal.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day), \(proposal.start.formatted(date: .omitted, time: .shortened)) to \(proposal.end.formatted(date: .omitted, time: .shortened))"
    }
}

/// The panel's "more" button: Forward..., Email Attendees and Export..., as Outlook's event menu
/// has them.
struct EventMoreMenu: View {
    @Bindable var store: CalendarStore
    let event: CalendarEvent

    var body: some View {
        Menu {
            Button("Forward...") { store.forwardSelected() }
                // The organizer turned forwarding off: only they may still forward it.
                .disabled(!event.isOrganizer && !allowsForwarding)
            Button("Email Attendees") { store.emailAttendees() }
                .disabled(!hasAttendees)
            Divider()
            Button("Export...") { Task { await store.exportSelected() } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

    private var allowsForwarding: Bool {
        if case .loaded(let detail) = store.detail { return detail.allowsForwarding }
        return true
    }

    private var hasAttendees: Bool {
        guard case .loaded(let detail) = store.detail, let me = store.account?.email else { return false }
        return !CalendarStore.attendeeAddresses(detail, me: me).isEmpty
    }
}
