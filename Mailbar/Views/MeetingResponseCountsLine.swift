import SwiftUI

/// On a meeting email about a meeting the user organized: "3 accepted, 1 tentative, 1 not
/// responded", from the calendar's copy, as Outlook's tracking line says it (2026-11-16).
struct MeetingResponseCountsLine: View {
    @Bindable var card: MeetingCard

    var body: some View {
        if card.isOrganizer, let details = card.details,
           let text = ResponseCounts(attendees: details.attendees, organizer: details.organizerAddress).text {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }
}
