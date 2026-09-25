import SwiftUI

/// Day, work week and week: days as columns, hours down the side, events as blocks by time.
/// After the user's OWA screenshot: the weekend shaded, hours outside work shaded, a strip for
/// all-day events, overlapping events side by side, tentative ones hatched.
struct CalendarWeekView: View {
    @Bindable var store: CalendarStore

    static let hourHeight: CGFloat = 54
    static let gutterWidth: CGFloat = 52

    var body: some View {
        let days = store.visibleDays
        VStack(spacing: 0) {
            header(days)
            if days.contains(where: { !store.allDayEvents(on: $0).isEmpty }) {
                allDayStrip(days)
                Divider().opacity(0.6)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    grid(days)
                }
                .onAppear {
                    // Start of the working day at the top, as OWA opens. A turn later, once the
                    // grid has been laid out, or there is nothing to scroll to yet.
                    let target = "hour-\(max(store.workHours.lowerBound - 1, 0))"
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                }
                .onChange(of: store.mode) { _, _ in
                    let target = "hour-\(max(store.workHours.lowerBound - 1, 0))"
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutterWidth, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = store.calendar.isDateInToday(day)
                VStack(alignment: .leading, spacing: 0) {
                    Text(day.formatted(.dateTime.day()) + " " + day.formatted(.dateTime.weekday(.wide)))
                        .font(.system(size: 13, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    Rectangle()
                        .fill(isToday ? Color.accentColor : Color.clear)
                        .frame(height: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
            }
        }
    }

    private func allDayStrip(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all day")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: Self.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 4)
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    ForEach(store.allDayEvents(on: day)) { event in
                        EventBlock(event: event, isSelected: store.selectedEventID == event.id, compact: true)
                            .frame(height: 20)
                            .onTapGesture { Task { await store.select(event) } }
                    }
                }
                .padding(3)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    // MARK: - Grid

    private func grid(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Hour labels: "9a", "12p", as OWA writes them.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(Self.hourLabel(hour))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.gutterWidth - 10, height: Self.hourHeight, alignment: .topLeading)
                        .padding(.leading, 10)
                        .offset(y: -7)
                        .id("hour-\(hour)")
                }
            }
            ForEach(days, id: \.self) { day in
                DayColumn(store: store, day: day)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.hourHeight * 24)
        .padding(.top, 8)
    }

    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case 13...23: return "\(hour - 12)p"
        default: return "\(hour)a"
        }
    }
}

/// One day: the shaded background, the hour lines, the events laid out side by side where they
/// overlap, and the current-time line on today.
private struct DayColumn: View {
    @Bindable var store: CalendarStore
    let day: Date

    private var hourHeight: CGFloat { CalendarWeekView.hourHeight }

    var body: some View {
        let calendar = store.calendar
        let isWorkDay = store.workDays.contains(calendar.component(.weekday, from: day))
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                // Off-hours and weekend shading: the user's OWA tints everything that is not work.
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        let working = isWorkDay && store.workHours.lowerBound <= hour && hour < store.workHours.upperBound
                        Rectangle()
                            .fill(working ? Color.clear : Color.accentColor.opacity(0.06))
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) {
                                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1)
                            }
                            .overlay(alignment: .center) {
                                // The half-hour line, fainter, as in OWA.
                                Rectangle().fill(Color.primary.opacity(0.04)).frame(height: 1)
                            }
                    }
                }
                Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1).frame(maxHeight: .infinity)

                ForEach(EventLayout.place(store.timedEvents(on: day), on: day, calendar: calendar)) { placed in
                    let x = CGFloat(placed.column) / CGFloat(placed.columns) * (width - 6) + 3
                    let w = (width - 6) / CGFloat(placed.columns) - 2
                    let y = placed.startHour * hourHeight
                    let h = max((placed.endHour - placed.startHour) * hourHeight - 2, 18)
                    EventBlock(event: placed.event, isSelected: store.selectedEventID == placed.event.id,
                               compact: h < 36)
                        .frame(width: max(w, 10), height: h)
                        .offset(x: x, y: y)
                        .onTapGesture { Task { await store.select(placed.event) } }
                }

                if calendar.isDateInToday(day) {
                    NowLine(calendar: calendar, hourHeight: hourHeight, width: width)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { Task { await store.select(nil) } }
        }
    }
}

/// A red line at the current time, refreshed every minute.
private struct NowLine: View {
    let calendar: Calendar
    let hourHeight: CGFloat
    let width: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let components = calendar.dateComponents([.hour, .minute], from: context.date)
            let y = (CGFloat(components.hour ?? 0) + CGFloat(components.minute ?? 0) / 60) * hourHeight
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.red).frame(width: width, height: 1.5)
                Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: -4)
            }
            .offset(y: y - 0.75)
            .allowsHitTesting(false)
        }
    }
}

/// One event's block. Light fill with a solid left bar, as OWA draws them; hatched when not yet
/// accepted; struck through when cancelled.
struct EventBlock: View {
    let event: CalendarEvent
    let isSelected: Bool
    var compact = false

    var body: some View {
        let tint = event.isCancelled ? Color.gray : Color.accentColor
        HStack(spacing: 0) {
            Rectangle().fill(event.isTentative ? tint.opacity(0.45) : tint).frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    DirectionalText(event.subject, font: .system(size: 11.5, weight: .semibold))
                        .strikethrough(event.isCancelled)
                    if event.isRecurring {
                        Image(systemName: "arrow.2.squarepath").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if event.isPrivate {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                if !compact {
                    let second = [event.location, event.organizer].filter { !$0.isEmpty }.joined(separator: "  ")
                    if !second.isEmpty {
                        DirectionalText(second, font: .system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                tint.opacity(isSelected ? 0.34 : 0.18)
                if event.isTentative { Hatching(color: tint.opacity(0.18)) }
            })
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
            .stroke(isSelected ? tint : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        let time = event.isAllDay ? "All day"
            : "\(event.start.formatted(date: .omitted, time: .shortened)) to \(event.end.formatted(date: .omitted, time: .shortened))"
        return [event.subject, time, event.location].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Diagonal stripes, OWA's mark for an event not yet accepted.
private struct Hatching: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// Places a day's timed events: overlapping events share the width in columns, the way every
/// calendar does it, so none is hidden under another.
enum EventLayout {
    struct Placed: Identifiable {
        let event: CalendarEvent
        /// Hours from midnight, clipped to this day (an event may start the day before).
        let startHour: CGFloat
        let endHour: CGFloat
        let column: Int
        let columns: Int
        var id: String { event.id }
    }

    static func place(_ events: [CalendarEvent], on day: Date, calendar: Calendar) -> [Placed] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        func hours(_ date: Date) -> CGFloat {
            CGFloat(min(max(date, dayStart), dayEnd).timeIntervalSince(dayStart) / 3600)
        }
        let sorted = events.sorted { ($0.start, $1.end) < ($1.start, $0.end) }

        var result: [Placed] = []
        var cluster: [(event: CalendarEvent, start: CGFloat, end: CGFloat, column: Int)] = []
        var clusterEnd: CGFloat = -1

        func flush() {
            let columns = (cluster.map(\.column).max() ?? 0) + 1
            result += cluster.map { Placed(event: $0.event, startHour: $0.start, endHour: $0.end,
                                           column: $0.column, columns: columns) }
            cluster.removeAll()
        }

        for event in sorted {
            let start = hours(event.start)
            // A zero-length event still gets a visible block.
            let end = max(hours(event.end), start + 0.25)
            if start >= clusterEnd { flush(); clusterEnd = -1 }
            // The first column whose last event has ended by now.
            var column = 0
            while cluster.contains(where: { $0.column == column && $0.end > start }) { column += 1 }
            cluster.append((event, start, end, column))
            clusterEnd = max(clusterEnd, end)
        }
        flush()
        return result
    }
}
