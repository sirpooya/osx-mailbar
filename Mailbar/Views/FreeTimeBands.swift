import SwiftUI

/// The Today tab's free time (2026-11-16, after Outlook's My Day): each gap of half an hour or
/// more inside the work hours, on a work day, as a faint band saying "Free 14:00 to 16:00".
struct FreeTimeBands: View {
    let events: [CalendarEvent]
    let day: Date
    let hourHeight: CGFloat
    let width: CGFloat
    let calendar: Calendar

    var body: some View {
        let dayStart = calendar.startOfDay(for: day)
        ForEach(FreeSlots.gaps(in: events, on: day, workHours: Keys.calendarWorkHours(),
                               workDays: Keys.calendarWorkDays(), calendar: calendar), id: \.start) { gap in
            let top = CGFloat(gap.start.timeIntervalSince(dayStart) / 3600) * hourHeight
            let height = CGFloat(gap.duration / 3600) * hourHeight
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.green.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .overlay(alignment: .topLeading) {
                    Text(FreeSlots.label(gap))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.green.opacity(0.85))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.top, 3)
                }
                .frame(width: max(width - 8, 10), height: max(height - 2, 8))
                .offset(x: 4, y: top + 1)
                .allowsHitTesting(false)
                .accessibilityLabel(FreeSlots.label(gap))
        }
    }
}
