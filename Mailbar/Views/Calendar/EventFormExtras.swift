import SwiftUI

/// The form's check before sending, in the bottom bar where Send is (2026-11-16, after Outlook's
/// "This message has no subject"): Don't Send goes back to the form, the other button goes on.
struct MissingWarningBar: View {
    let warning: EventDraft.MissingWarning
    let savingOnly: Bool
    let onBack: () -> Void
    let onGo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(savingOnly ? warning.question.replacingOccurrences(of: "Send", with: "Save") : warning.question)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button(savingOnly ? "Don't Save" : "Don't Send", action: onBack)
                .keyboardShortcut(.cancelAction)
            Button(savingOnly ? "Save Anyway" : "Send Anyway", action: onGo)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The chevron beside Send on a meeting: Save Without Sending writes the event and tells nobody
/// (`SendToNone`); the form opens on it later and Send invites everyone then.
struct SendOptionsMenu: View {
    let onSaveOnly: () -> Void

    var body: some View {
        Menu {
            Button("Save Without Sending", action: onSaveOnly)
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save Without Sending (Option-click Send)")
        .accessibilityLabel("Send options")
    }
}

/// Outlook's Time zones, in the form's toolbar beside Private and drawn like it: on, a zone sits
/// beside Starts and beside Ends (a flight from one city to another).
struct TimeZonesButton: View {
    let draft: EventDraft
    @Bindable var store: CalendarStore

    var body: some View {
        let on = draft.usesTimeZones
        Button {
            let here = WindowsTimeZone.current ?? "UTC"
            store.editor?.startTimeZone = on ? nil : here
            store.editor?.endTimeZone = on ? nil : here
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe").font(.system(size: 11))
                Text("Time zones")
            }
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.primary.opacity(0.08) : Color.clear))
        }
        .buttonStyle(.borderless)
        .disabled(draft.isAllDay)
        .help("Set the start and the end in different time zones")
        .accessibilityValue(on ? "On" : "Off")
    }
}
