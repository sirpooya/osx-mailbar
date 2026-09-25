import AppKit
import SwiftUI

/// Month: six weeks of days, up to three events each and a count of the rest. Clicking a day opens
/// it in Day view; clicking an event selects it.
struct CalendarMonthView: View {
    @Bindable var store: CalendarStore

    private static let perCell = 3

    var body: some View {
        let calendar = store.calendar
        VStack(spacing: 0) {
            GeometryReader { proxy in
                weekdayRow(Array(store.monthGridDays.prefix(7)), width: proxy.size.width)
            }
            .frame(height: 28)
            // Months slide as weeks do: the grid follows the fingers and springs to the next.
            PagerStrip(pager: store.pager, measures: true) { page in
                grid(days: store.monthGridDays(page: page), month: store.month(page: page), calendar: calendar)
            }
        }
    }

    /// Weekday names in ONE format across the row, the longest that fits every column.
    private func weekdayRow(_ days: [Date], width: CGFloat) -> some View {
        let font = NSFont.systemFont(ofSize: 12)
        let column = width / 7 - 16
        let formats: [Date.FormatStyle.Symbol.Weekday] = [.wide, .abbreviated, .narrow]
        let chosen = formats.first { format in
            days.allSatisfy { (($0.formatted(.dateTime.weekday(format))) as NSString).size(withAttributes: [.font: font]).width <= column }
        } ?? .narrow
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                Text(day.formatted(.dateTime.weekday(chosen)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func grid(days: [Date], month: Int, calendar: Calendar) -> some View {
        GeometryReader { proxy in
            let rowHeight = proxy.size.height / 6
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(days[(row * 7)..<(row * 7 + 7)], id: \.self) { day in
                            cell(day, inMonth: calendar.component(.month, from: day) == month, calendar: calendar)
                                .frame(maxWidth: .infinity, maxHeight: rowHeight, alignment: .topLeading)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
    }

    private func cell(_ day: Date, inMonth: Bool, calendar: Calendar) -> some View {
        let events = store.events(on: day)
        let isToday = calendar.isDateInToday(day)
        let isWorkDay = store.workDays.contains(calendar.component(.weekday, from: day))
        return VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 12, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary))
                .frame(minWidth: 20, minHeight: 20)
                .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
            ForEach(events.prefix(Self.perCell)) { event in
                HStack(spacing: 4) {
                    Circle().fill(store.tint(for: event)).frame(width: 6, height: 6)
                    if !event.isAllDay {
                        Text(event.start.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    DirectionalText(event.subject, font: .system(size: 11))
                        .strikethrough(event.isCancelled)
                }
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(store.selectedEventID == event.id ? Color.accentColor.opacity(0.25) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { Task { await store.select(event) } }
            }
            if events.count > Self.perCell {
                Text("+\(events.count - Self.perCell) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        // The whole cell, before the fill and the border, or both shrink to the text inside.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Weekends in neutral grey, as in the week grid (the user's call, 2026-09-25).
        .background(isWorkDay ? Color.clear : CalendarSurface.shade)
        .overlay {
            Rectangle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(day: day) }
        .opacity(inMonth ? 1 : 0.55)
    }
}
