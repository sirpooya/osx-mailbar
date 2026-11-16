import SwiftUI

/// "Automatic Replies..." (2026-11-16, after Outlook): Off, On, or only during a period; a
/// message for people inside the organization; whether people outside get one, and theirs.
///
/// Read fresh from the server when it opens and written back whole on Save. The messages are
/// HTML on the server and plain text here; a message left untouched goes back exactly as it came.
struct AutoReplySheet: View {
    let account: Account
    let onClose: () -> Void

    private let health = AccountHealth.shared

    enum Mode: String, CaseIterable, Identifiable {
        case off = "Off"
        case on = "On"
        case period = "During a period"
        var id: String { rawValue }
    }

    @State private var loaded: AutoReplySettings?
    @State private var mode: Mode = .off
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(24 * 60 * 60)
    @State private var audience: AutoReplySettings.Audience = .all
    @State private var insideText = ""
    @State private var outsideText = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FocusSink().frame(width: 0, height: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic Replies")
                    .font(.system(size: 15, weight: .semibold))
                Text(account.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, SettingsMetrics.rowHPadding)

            if let loadError {
                SettingsFootnote(loadError, tint: .orange)
            } else if loaded == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Reading the automatic replies...")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SettingsMetrics.rowHPadding)
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else {
                form
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.rowHPadding)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Saving..." : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(loaded == nil || isSaving || periodProblem != nil)
            }
        }
        .padding(SettingsMetrics.bodyHPadding)
        .frame(width: SettingsMetrics.windowWidth + 40)
        .task { await load() }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(footnote: periodProblem) {
                SettingsRow("Replies") {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if mode == .period {
                    SettingsDivider()
                    SettingsRow("Starts") {
                        DatePicker("", selection: $start).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("Ends") {
                        DatePicker("", selection: $end).labelsHidden()
                    }
                }
            }

            Group {
                SettingsSection("Inside my organization") {
                    messageEditor($insideText)
                }

                SettingsSection("Outside my organization") {
                    SettingsRow("Reply to") {
                        Picker("", selection: $audience) {
                            ForEach(AutoReplySettings.Audience.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if audience != .none {
                        SettingsDivider()
                        messageEditor($outsideText)
                    }
                }
            }
            // The messages stay editable but dimmed while replies are off, as in Outlook.
            .opacity(mode == .off ? 0.55 : 1)
        }
        .animation(.snappy(duration: 0.2), value: mode)
        .animation(.snappy(duration: 0.2), value: audience)
    }

    /// Plain text; each paragraph takes its own direction, so Persian lines read right to left.
    private func messageEditor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(height: 76)
            .padding(.horizontal, SettingsMetrics.rowHPadding - 5)
            .padding(.vertical, 8)
    }

    private var periodProblem: String? {
        mode == .period && end <= start ? "The end must come after the start." : nil
    }

    // MARK: - Loading and saving

    private func load() async {
        do {
            let settings = try await health.loadAutoReplies(for: account)
            apply(settings)
        } catch is CancellationError {
        } catch {
            loadError = describe(error)
        }
    }

    private func apply(_ settings: AutoReplySettings) {
        loaded = settings
        switch settings.state {
        case .disabled: mode = .off
        case .enabled: mode = .on
        case .scheduled: mode = .period
        }
        start = settings.start
        end = settings.end
        // A period long past is not a useful starting point: offer the next day instead.
        if settings.state != .scheduled, end < Date() {
            start = Date()
            end = Date().addingTimeInterval(24 * 60 * 60)
        }
        audience = settings.audience
        #if DEBUG
        // `--auto-replies-period` (DEBUG): the period rows, for a screenshot.
        if CommandLine.arguments.contains("--auto-replies-period") { mode = .period }
        #endif
        insideText = AutoReplyText.plainText(fromHTML: settings.internalHTML)
        outsideText = AutoReplyText.plainText(fromHTML: settings.externalHTML)
    }

    /// What Save sends: the form over what was read, a message rewritten only when its text
    /// changed.
    private var edited: AutoReplySettings? {
        guard var settings = loaded else { return nil }
        switch mode {
        case .off: settings.state = .disabled
        case .on: settings.state = .enabled
        case .period: settings.state = .scheduled
        }
        settings.start = start
        settings.end = end
        settings.audience = audience
        if insideText != AutoReplyText.plainText(fromHTML: settings.internalHTML) {
            settings.internalHTML = AutoReplyText.html(fromPlainText: insideText)
        }
        if outsideText != AutoReplyText.plainText(fromHTML: settings.externalHTML) {
            settings.externalHTML = AutoReplyText.html(fromPlainText: outsideText)
        }
        return settings
    }

    private func save() async {
        guard let settings = edited else { return }
        guard settings != loaded else { onClose(); return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await health.saveAutoReplies(settings, for: account)
            onClose()
        } catch is CancellationError {
        } catch {
            saveError = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? EWSError)?.message(host: account.host) ?? error.localizedDescription
    }
}
