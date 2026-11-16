import AppKit
import SwiftUI

/// Settings, General (M26): the new-mail and mail-sent sounds. Picking one plays it.
struct SoundsSettingsSection: View {
    @AppStorage(Keys.newMailSound) private var newMail = MailSounds.systemDefault
    @AppStorage(Keys.sentSound) private var sent = MailSounds.none

    var body: some View {
        SettingsSection("Sounds") {
            SettingsRow("New mail") { picker($newMail, offersDefault: true) }
            SettingsDivider()
            SettingsRow("Mail sent") { picker($sent, offersDefault: false) }
        }
    }

    private func picker(_ selection: Binding<String>, offersDefault: Bool) -> some View {
        Picker("", selection: selection) {
            Text("None").tag(MailSounds.none)
            if offersDefault { Text("Default").tag(MailSounds.systemDefault) }
            Divider()
            ForEach(MailSounds.systemNames, id: \.self) { name in Text(name).tag(name) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .onChange(of: selection.wrappedValue) { _, choice in MailSounds.play(choice) }
    }
}

/// Settings, General (M26): what the menu bar number counts.
struct MenuBarSettingsSection: View {
    @AppStorage(Keys.menuBarCount) private var mode = MenuBarCount.allAccounts.rawValue

    var body: some View {
        SettingsSection("Menu bar") {
            SettingsRow("Unread count") {
                Picker("", selection: $mode) {
                    ForEach(MenuBarCount.allCases) { choice in Text(choice.title).tag(choice.rawValue) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

/// Settings, General (M26): which app opens mailto: links, and a button to make it Mailbar.
/// macOS asks the user to confirm the change itself.
struct DefaultMailAppSection: View {
    @State private var current: String?
    @State private var isMailbar = false
    @State private var problem: String?

    var body: some View {
        SettingsSection("Default mail app", footnote: problem) {
            SettingsRow(current ?? "None") {
                if isMailbar {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Make Default", action: makeDefault)
                        .controlSize(.small)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        guard let probe = URL(string: "mailto:someone@example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            current = nil
            isMailbar = false
            return
        }
        current = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        isMailbar = Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func makeDefault() {
        problem = nil
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { error in
            let message = error.flatMap { error -> String? in
                // Cancelled in macOS's own prompt, or the scheme is not one this build declares.
                (error as NSError).code == NSUserCancelledError ? nil : "Could not change it: \(error.localizedDescription)"
            }
            Task { @MainActor in
                problem = message
                refresh()
            }
        }
    }
}

/// Settings, Calendar (M26): whether today's events go to the widgets. Off deletes the file.
struct WidgetsSettingsSection: View {
    @AppStorage(Keys.widgetEvents) private var enabled = true

    var body: some View {
        SettingsSection("Widgets", footnote: "Only today's times, titles, places and Join links.") {
            SettingsRow("Show events in widgets") {
                SettingsSwitch(isOn: $enabled)
            }
        }
    }
}
