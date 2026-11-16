import SwiftUI

/// Outlook's Shorten events (2026-11-16): a new event, double-clicked or dragged out, ends 5 or
/// 10 minutes early, leaving time to get to the next one. Events under half an hour keep their
/// length.
struct ShortenEventsRow: View {
    @AppStorage(Keys.calendarShortenMinutes) private var minutes = 0

    var body: some View {
        SettingsRow("Shorten events") {
            Picker("", selection: $minutes) {
                Text("None").tag(0)
                Text("End 5 min early").tag(5)
                Text("End 10 min early").tag(10)
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}
