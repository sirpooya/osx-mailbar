import AppKit
import SwiftUI

/// DEBUG only: puts the calendar extras (2026-11-16) on screen without a click, for `mac-qc`
/// on a host with no Accessibility grant. `--calendar-qc=<state>`, mock mode:
///
///     series-edit, series-delete     a repeating event's "which part" question
///     series-all, series-following   the form on the whole series, or on this and following
///     invitee-delete                 Delete on someone else's meeting
///     proposals                      a meeting of the user's with proposed times and counts
///     timezones                      the form with a zone beside Starts and Ends
///     warn-title, warn-location      the bottom bar's check before sending
///     unsent                         a meeting saved without sending, opened again
///     ics                            Add to Calendar's sheet for a sample file
@MainActor
enum CalendarQC {
    static func apply(to store: CalendarStore) {
        #if DEBUG
        guard let state = QCFlags.calendarQC, MockMode.current != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await run(state, store: store)
        }
        #endif
    }

    private static func select(_ title: String, in store: CalendarStore) async {
        guard let event = store.events.first(where: { $0.subject == title }) else { return }
        await store.select(event)
    }

    private static func newMeeting(_ store: CalendarStore, title: String) {
        store.startNewEvent()
        store.editor?.subject = title
        store.editor?.people = [.init(name: "Sara Rahimi", address: "sara.rahimi@example.com"),
                                .init(name: "Omid Karimi", address: "omid@example.org")]
    }

    private static func run(_ state: String, store: CalendarStore) async {
        switch state {
        case "series-edit", "series-delete":
            await select("Room For Weekly", in: store)
            store.askingSeries = state == "series-edit" ? .edit : .delete
        case "series-all", "series-following":
            await select("Room For Weekly", in: store)
            await store.startEditing(scope: state == "series-all" ? .all : .following)
        case "invitee-delete":
            await select("Design Weekly", in: store)
            store.askingInviteeDelete = true
        case "proposals":
            await select("ds demo alignment", in: store)
        case "timezones":
            newMeeting(store, title: "Flight to Istanbul")
            store.editor?.location = "IKA"
            store.editor?.startTimeZone = WindowsTimeZone.current ?? "Iran Standard Time"
            store.editor?.endTimeZone = "Turkey Standard Time"
        case "warn-title":
            newMeeting(store, title: "")
            store.pendingWarning = .title
        case "warn-location":
            newMeeting(store, title: "Design review")
            store.pendingWarning = .location
        case "unsent":
            await select("ds demo alignment", in: store)
            store.startEditing()
            store.editor?.invitationsUnsent = true
        case "ics":
            showICSSheet(store.mail)
        default:
            break
        }
    }

    private static var icsWindow: NSWindow?

    /// The sheet the reader's Add to Calendar opens, for a sample file, in a window of its own.
    private static func showICSSheet(_ mail: MailStore) {
        let events = ICalendar.events(in: Data(MockCalendar.sampleICS.utf8))
        let sheet = ICSImportSheet(file: nil, accountID: mail.selectedAccount?.id ?? UUID(), store: mail,
                                   onClose: { icsWindow?.close() }, preloaded: events)
        let window = NSWindow(contentViewController: NSHostingController(rootView: sheet))
        window.title = "Add to Calendar"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        icsWindow = window
    }
}
