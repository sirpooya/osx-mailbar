import Foundation

extension Notification.Name {
    /// The calendar started a message: the popover comes up on the composer.
    static let mailbarShowComposer = Notification.Name("in.pooya.mailbar.showComposer")
}

/// The calendar's ways into the composer (2026-11-16): forwarding an event and mailing its
/// attendees. The draft is the composer's own, in memory like any other; an unsent draft with
/// text in it is never replaced, the composer shows it instead.
extension MailStore {
    /// A forward of the calendar item itself: `ForwardItem` takes an event as it takes a message,
    /// and the server builds the forwarded invitation.
    func startEventForward(eventID: String, subject: String, accountID: UUID) {
        if let draft, draft.hasContent {
            showComposerFromCalendar()
            return
        }
        draft = Draft(kind: .forward, accountID: accountID, originalID: eventID, originalSubject: subject,
                      to: "", cc: "", subject: "", body: "")
        showComposerFromCalendar()
    }

    /// A new message to everyone on the event but the user, its title as the subject.
    func startEventEmail(to addresses: [String], subject: String, accountID: UUID) {
        if let draft, draft.hasContent {
            showComposerFromCalendar()
            return
        }
        draft = Draft(kind: .new, accountID: accountID, originalID: nil, originalSubject: "",
                      to: addresses.isEmpty ? "" : Recipients.join(addresses) + ", ", cc: "", subject: subject, body: "")
        showComposerFromCalendar()
    }

    private func showComposerFromCalendar() {
        isComposing = true
        NotificationCenter.default.post(name: .mailbarShowComposer, object: nil)
    }
}
