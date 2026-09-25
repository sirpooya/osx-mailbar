import AppKit
import SwiftUI

/// Day, work week and week: days as columns, hours down the side, events as blocks by time.
/// After the user's OWA screenshot: the weekend shaded, hours outside work shaded, a strip for
/// all-day events, overlapping events side by side, tentative ones hatched.
struct CalendarWeekView: View {
    @Bindable var store: CalendarStore

    static let hourHeight: CGFloat = 54
    static let gutterWidth: CGFloat = 52
    static let headerHeight: CGFloat = 38
    static let allDayRowHeight: CGFloat = 22

    var body: some View {
        // The all-day strip is as tall as the busiest day on any of the three pages, so it does
        // not change height as a swipe brings in a week with more (or fewer) all-day events.
        let allDayRows = (-1...1).flatMap { store.days(page: $0) }.map { store.allDayEvents(on: $0).count }.max() ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutterWidth, height: 1)
                PagerStrip(pager: store.pager) { page in
                    GeometryReader { proxy in
                        header(store.days(page: page), width: proxy.size.width)
                    }
                }
            }
            .frame(height: Self.headerHeight)
            if allDayRows > 0 {
                HStack(spacing: 0) {
                    Text("all day")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: Self.gutterWidth - 6, alignment: .trailing)
                        .padding(.trailing, 6)
                    PagerStrip(pager: store.pager) { page in allDayStrip(store.days(page: page)) }
                }
                .frame(height: CGFloat(allDayRows) * Self.allDayRowHeight + 6)
                Divider().opacity(0.6)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        PagerStrip(pager: store.pager, measures: true) { page in
                            HStack(spacing: 0) {
                                ForEach(store.days(page: page), id: \.self) { day in
                                    DayColumn(store: store, day: day)
                                }
                            }
                        }
                    }
                    .frame(height: Self.hourHeight * 24)
                    .padding(.top, 8)
                }
                .onAppear {
                    // Start of the working day at the top, as OWA opens. A turn later, once the
                    // grid has been laid out, or there is nothing to scroll to yet.
                    let target = "hour-\(max(store.workHours.lowerBound - 1, 0))"
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }

    // MARK: - Pieces

    /// "19 Saturday", "Sat 19" or "19", ONE format for the whole row, as Calendar does: the
    /// longest that fits every column. Choosing per column mixed "19 Saturday" with "Wed 23".
    static func dayLabelStyle(for days: [Date], width: CGFloat) -> Int {
        guard !days.isEmpty else { return 0 }
        let column = width / CGFloat(days.count) - 16
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        func widest(_ label: (Date) -> String) -> CGFloat {
            days.map { (label($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        }
        if widest({ dayLabel($0, style: 0) }) <= column { return 0 }
        if widest({ dayLabel($0, style: 1) }) <= column { return 1 }
        return 2
    }

    static func dayLabel(_ day: Date, style: Int) -> String {
        switch style {
        case 0: return day.formatted(.dateTime.day()) + " " + day.formatted(.dateTime.weekday(.wide))
        case 1: return day.formatted(.dateTime.weekday(.abbreviated)) + " " + day.formatted(.dateTime.day())
        default: return day.formatted(.dateTime.day())
        }
    }

    private func header(_ days: [Date], width: CGFloat) -> some View {
        let style = Self.dayLabelStyle(for: days, width: width)
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let isToday = store.calendar.isDateInToday(day)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.dayLabel(day, style: style))
                    .font(.system(size: 13, weight: isToday ? .semibold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity, alignment: .center)
                    Rectangle()
                        .fill(isToday ? Color.accentColor : Color.clear)
                        .frame(height: 3)
                }
                // No fill: a plain row of day names over the grid, as in Apple's Calendar (the user
                // asked for the grey band gone, 2026-09-25).
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func allDayStrip(_ days: [Date]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(days, id: \.self) { day in
                VStack(spacing: 2) {
                    ForEach(store.allDayEvents(on: day)) { event in
                        EventBlock(event: event, isSelected: store.selectedEventID == event.id, compact: true,
                                   tint: store.tint(for: event))
                            .frame(height: Self.allDayRowHeight - 2)
                            .onTapGesture { Task { await store.select(event) } }
                    }
                }
                .padding(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// Hour labels: "9a", "12p", as OWA writes them. Fixed: it does not slide with the days.
    private var hourGutter: some View {
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
        .background(CalendarSurface.background)
        .zIndex(1)
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
                HourBackground(isWorkDay: isWorkDay, workHours: store.workHours, hourHeight: hourHeight)

                // The empty grid takes the clicks and drags; a drag that starts on an event lands
                // on the event instead, so it never draws a new one over it.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(newEventDrag)
                    // Double-click an empty slot: a new event there, on the half hour, as Calendar does.
                    .onTapGesture(count: 2) { location in
                        store.startNewEvent(at: slot(at: location.y, step: 30, rounding: .down))
                    }
                    .onTapGesture { Task { await store.select(nil) } }

                ForEach(EventLayout.place(store.timedEvents(on: day), on: day, calendar: calendar)) { placed in
                    let x = CGFloat(placed.column) / CGFloat(placed.columns) * (width - 6) + 3
                    let w = (width - 6) / CGFloat(placed.columns) - 2
                    let y = placed.startHour * hourHeight
                    let h = max((placed.endHour - placed.startHour) * hourHeight - 2, 18)
                    EventBlock(event: placed.event, isSelected: store.selectedEventID == placed.event.id,
                               compact: h < 36, tint: store.tint(for: placed.event), height: h,
                               width: max(w, 10))
                        .frame(width: max(w, 10), height: h)
                        .offset(x: x, y: y)
                        .onTapGesture { Task { await store.select(placed.event) } }
                }

                if let dragged = store.draggedRange, calendar.isDate(dragged.lowerBound, inSameDayAs: day) {
                    NewEventGhost(start: dragged.lowerBound, end: dragged.upperBound, height: hourHeight)
                        .frame(width: max(width - 8, 10))
                        .offset(x: 3, y: hours(dragged.lowerBound) * hourHeight)
                }

                if calendar.isDateInToday(day) {
                    NowLine(calendar: calendar, hourHeight: hourHeight, width: width)
                }
            }
        }
        // The dragged block stays on the grid while the form is open, as Calendar keeps it, and
        // goes when the form does (a saved event then shows in its place).
        .onChange(of: store.editor == nil) { _, closed in if closed { store.draggedRange = nil } }
    }

    // MARK: - Drag to create

    /// Press on an empty slot and drag up or down: a block follows in 15-minute steps, and letting
    /// go opens the form over that range, as Apple's Calendar does. Within the one day.
    private var newEventDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let a = slot(at: value.startLocation.y, step: 15, rounding: .down)
                let b = slot(at: value.location.y, step: 15, rounding: .down)
                let quarter: TimeInterval = 15 * 60
                // The slot under the pointer counts, whichever way the drag goes.
                let range = min(a, b)...max(a, b).addingTimeInterval(quarter)
                if range != store.draggedRange { store.draggedRange = range }
            }
            .onEnded { _ in
                guard let range = store.draggedRange else { return }
                store.startNewEvent(at: range.lowerBound, until: range.upperBound)
                if store.editor == nil { store.draggedRange = nil }
            }
    }

    /// The time at a point down the column, in whole steps of minutes, kept inside the day.
    private func slot(at y: CGFloat, step: Int, rounding: FloatingPointRoundingRule) -> Date {
        let minutes = Int((y / hourHeight * 60 / CGFloat(step)).rounded(rounding)) * step
        return store.calendar.date(byAdding: .minute, value: max(0, min(minutes, 24 * 60 - step)),
                                   to: store.calendar.startOfDay(for: day)) ?? day
    }

    private func hours(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(store.calendar.startOfDay(for: day)) / 3600)
    }
}

/// The block a drag draws before the event exists: the accent's selected look, "New Event" and
/// the times it covers, so the range can be read while dragging.
private struct NewEventGhost: View {
    let start: Date
    let end: Date
    let height: CGFloat

    var body: some View {
        let h = max(CGFloat(end.timeIntervalSince(start) / 3600) * height - 2, 12)
        let times = "\(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))"
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(Color.accentColor).frame(width: EventBlock.barWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Event").font(.system(size: 11.5, weight: .semibold))
                if h >= 30 {
                    Text(times).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, h >= 18 ? 3 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: h)
        .background(Color.accentColor.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Color.accentColor, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityLabel("New event, \(times)")
    }
}

/// The day's shading and lines in one drawing pass instead of a hundred views per column, so the
/// strip stays smooth while it follows the fingers. Weekends and hours outside work are a neutral
/// grey (the user's call, 2026-09-25), not a tint of the accent colour.
struct HourBackground: View {
    let isWorkDay: Bool
    let workHours: ClosedRange<Int>
    let hourHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let offHours = CalendarSurface.shade
            let line = Color.primary.opacity(0.09)
            let halfLine = Color.primary.opacity(0.04)
            for hour in 0..<24 {
                let y = CGFloat(hour) * hourHeight
                let working = isWorkDay && workHours.lowerBound <= hour && hour < workHours.upperBound
                if !working {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: hourHeight)), with: .color(offHours))
                }
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(line))
                context.fill(Path(CGRect(x: 0, y: y + hourHeight / 2, width: size.width, height: 1)), with: .color(halfLine))
            }
            context.fill(Path(CGRect(x: 0, y: 0, width: 1, height: size.height)), with: .color(line))
        }
        .allowsHitTesting(false)
    }
}

/// A red line at the current time, refreshed every minute.
struct NowLine: View {
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
    /// The event's category colour, or the accent (`CalendarStore.tint(for:)`).
    var tint: Color = .accentColor
    /// The block's height, so a narrow block can let its title wrap onto the lines it has room
    /// for, as Calendar does ("Core / Weekly"), instead of cutting it to "Co...".
    var height: CGFloat = 20

    /// The block's width, for the same reason.
    var width: CGFloat = 200

    /// Regular weight: the titles read light (the user's call).
    private static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    /// The coloured bar at a block's leading edge: 2 pt, half what it was (the user's call).
    static let barWidth: CGFloat = 2

    /// Wraps only between words, as Calendar does. SwiftUI will otherwise break a word that does
    /// not fit its line ("Desig / n Syste / m W..."), so when the longest word is wider than the
    /// room a line has, the title stays on one line and truncates instead.
    private var titleLines: Int {
        guard !compact else { return 1 }
        let byHeight = max(1, min(4, Int((height - 6) / 14)))
        guard byHeight > 1 else { return 1 }
        let icons: CGFloat = (event.isRecurring ? 13 : 0) + (event.isPrivate ? 12 : 0) + (event.charm != nil ? 14 : 0)
        let room = width - Self.barWidth - 10 - icons
        let longest = event.subject.split(whereSeparator: \.isWhitespace)
            .map { (String($0) as NSString).size(withAttributes: [.font: Self.titleFont]).width }
            .max() ?? 0
        return longest > room ? 1 : byHeight
    }

    /// Outlook's category colours are pastels, so a categorised event is filled much more
    /// strongly than the accent's light wash, or the colour would barely show.
    private var fillOpacity: Double {
        // A colourless category is Outlook's pale grey block, not a strong grey one.
        if tint == CategoryColors.neutral { return isSelected ? 0.4 : 0.22 }
        let categorised = !event.categories.isEmpty && !event.isCancelled
        switch (categorised, isSelected) {
        case (true, false): return 0.55
        case (true, true): return 0.8
        case (false, false): return 0.18
        case (false, true): return 0.34
        }
    }

    var body: some View {
        // Top-aligned, as Outlook lays a block out: title in the top corner, second line under it,
        // not both floating in the middle of a tall event.
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(event.isTentative ? tint.opacity(0.45) : tint).frame(width: Self.barWidth)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    // The charm leads the title, as OWA draws it.
                    if let charm = event.charm.flatMap(EventCharm.init) {
                        Image(systemName: charm.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    DirectionalText(event.subject, font: .system(size: 11.5, weight: .regular), lines: titleLines)
                        .strikethrough(event.isCancelled)
                        .layoutPriority(1)
                    if event.isRecurring {
                        Image(systemName: "arrow.2.squarepath").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if event.isPrivate {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                // The title has first claim on the room; the place and organizer take what is left,
                // and drop out of a block too small for both.
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                tint.opacity(fillOpacity)
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
