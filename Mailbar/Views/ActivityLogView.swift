import AppKit
import SwiftUI

/// Settings, Accounts, "Activity Log...": the account's last failed requests, newest first,
/// with Copy and Clear. In memory only; quitting clears it.
struct ActivityLogView: View {
    let account: Account
    let onClose: () -> Void

    private let log = ActivityLog.shared

    var body: some View {
        let entries = log.entries(for: account)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity Log")
                    .font(.system(size: 15, weight: .semibold))
                Text(account.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, SettingsMetrics.rowHPadding)

            SettingsCard {
                if entries.isEmpty {
                    Text("No failed requests since Mailbar started.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { SettingsDivider() }
                                row(entry)
                            }
                        }
                    }
                    .frame(height: 240)
                }
            }

            SettingsFootnote("Failed requests only, the last \(ActivityLog.limit). Kept in memory and cleared when Mailbar quits.")

            HStack(spacing: 8) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ActivityLog.text(of: entries), forType: .string)
                }
                .disabled(entries.isEmpty)
                Button("Clear") { log.clear(account) }
                    .disabled(entries.isEmpty)
                Spacer(minLength: 0)
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SettingsMetrics.bodyHPadding)
        .frame(width: SettingsMetrics.windowWidth + 40)
    }

    private func row(_ entry: ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.operation).font(.system(size: 12, weight: .medium))
                Text(entry.host).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(entry.time.formatted(.dateTime.day().month(.abbreviated).hour().minute().second()))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, SettingsMetrics.rowHPadding)
        .padding(.vertical, 7)
    }
}
