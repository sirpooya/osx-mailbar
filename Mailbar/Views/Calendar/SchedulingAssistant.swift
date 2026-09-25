import SwiftUI

/// The event form's Schedule view, Outlook's Scheduling Assistant (the user's request,
/// 2026-09-25), a segment beside Event in the form, never a sheet of its own: everyone on the event, you
/// first, then the people and rooms invited, one row each across the day's hours with their busy
/// blocks from the server's free/busy (`GetUserAvailability`). The meeting is the accent band; a
/// click on the grid moves it there, in half hours, keeping its length. Next free time finds the
/// first slot everyone has open. Nothing is kept: the blocks live while the view is up.
///
/// The hours run as one strip across the work days around the meeting, each day only its work
/// hours (Settings, Calendar), so a swipe runs straight on into the next working day with no
/// empty evening or weekend between (the user's call, after Outlook's "Show work hours only").
struct SchedulingAssistant: View {
    @Bindable var store: CalendarStore

    /// The strip's middle: its first day is a week before, and it runs `stripDays` days.
    @State private var anchor = Date()
    /// The day at the strip's left edge as it scrolls, for the header.
    @State private var visibleDay: Date?
    /// Bumped to scroll the strip to the meeting: on opening, the arrows, Next free time.
    @State private var scrollRequest = 0
    /// The strip as it was when a drag began, held until it ends: the meeting's own day stretches
    /// to take it in, and a strip that changed under the hand made the band slip.
    @State private var dragTimeline: ScheduleTimeline?
    @State private var blocks: [String: [BusyBlock]?] = [:]
    @State private var loading = true
    @State private var failed = false
    /// The meeting's times when a drag on its band began, and which part was taken: the middle
    /// moves it, an edge resizes it. Nil while no drag is under way.
    @State private var dragOrigin: (start: Date, end: Date, part: BandPart)?

    enum BandPart { case move, start, end }

    // Dense, after Outlook's: short rows, thin lines, a band per section.
    private static let hourWidth: CGFloat = 48
    private static let rowHeight: CGFloat = 24
    private static let sectionHeight: CGFloat = 20
    private static let dayRowHeight: CGFloat = 18
    private static let hourRowHeight: CGFloat = 18
    private static var timelineHeight: CGFloat { dayRowHeight + hourRowHeight }
    private static let stripDays = 28
    /// Wide enough for a room's full name ("building | floor | room"), the user's call.
    /// Narrow, giving the hours the room (the user's call); a long name is cut, whole in its tooltip.
    private static let nameWidth: CGFloat = 200
    private static let gridSpace = "scheduleGrid"
    private static let viewportSpace = "scheduleViewport"

    private var stripStart: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: anchor)) ?? anchor
    }

    /// The strip now, or as it was when the drag under way began.
    private var timeline: ScheduleTimeline {
        if let dragTimeline { return dragTimeline }
        return ScheduleTimeline(first: stripStart, days: Self.stripDays, workDays: Keys.calendarWorkDays(),
                                workHours: Keys.calendarWorkHours(),
                                meeting: draft.map { ($0.start, $0.end) }, hourWidth: Self.hourWidth)
    }

    private var draft: EventDraft? { store.editor }

    struct Row {
        let name: String
        let address: String
        /// Set for a room: booked or only a candidate from Check availability.
        var room: Room?
    }

    /// You, then the people, then the rooms: booked ones, then the candidates to compare.
    private var people: [Row] {
        var rows: [Row] = []
        if let account = store.account, !account.email.isEmpty {
            rows.append(Row(name: account.fullName.isEmpty ? account.email : account.fullName, address: account.email))
        }
        for person in draft?.people ?? [] { rows.append(Row(name: person.display, address: person.address)) }
        for room in (draft?.rooms ?? []) + (draft?.candidateRooms ?? []) {
            rows.append(Row(name: room.name, address: room.address, room: room))
        }
        return rows
    }

    /// The rows as drawn: an Attendees band over the people, a Rooms band over the rooms.
    private enum Line {
        case section(String)
        case row(Row)
    }

    private var lines: [Line] {
        let rows = people
        var lines: [Line] = [.section("Attendees")]
        lines += rows.filter { $0.room == nil }.map { .row($0) }
        let rooms = rows.filter { $0.room != nil }
        if !rooms.isEmpty { lines += [.section("Rooms")] + rooms.map { .row($0) } }
        return lines
    }

    private var linesHeight: CGFloat {
        lines.reduce(0) { total, line in
            if case .section = line { return total + Self.sectionHeight }
            return total + Self.rowHeight
        }
    }

    /// Ticking a room books it; unticking puts it back among the candidates.
    private func bookedBinding(_ room: Room) -> Binding<Bool> {
        Binding(get: { store.editor?.rooms.contains(room) == true }, set: { book in
            if book {
                store.editor?.candidateRooms.removeAll { $0 == room }
                if store.editor?.rooms.contains(room) == false { store.editor?.rooms.append(room) }
            } else {
                store.editor?.rooms.removeAll { $0 == room }
                if store.editor?.candidateRooms.contains(room) == false { store.editor?.candidateRooms.append(room) }
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: Self.timelineHeight)
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            switch line {
                            case .section(let title):
                                sectionBand {
                                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.leading, 12)
                                }
                            case .row(let person):
                                nameCell(person)
                            }
                        }
                    }
                    .frame(width: Self.nameWidth)
                    Divider().opacity(0.6)
                    // Opens at the meeting, which may sit past the hours in view.
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) { grid }
                            .coordinateSpace(name: Self.viewportSpace)
                            .onPreferenceChange(DayEdgeKey.self) { edges in
                                // The last day whose start has scrolled to the left edge or past it.
                                let shown = edges.filter { $0.value <= 1 }.max { $0.value < $1.value }?.key
                                    ?? edges.min { $0.value < $1.value }?.key
                                MainActor.assumeIsolated { visibleDay = shown }
                            }
                            .onAppear { scroll(proxy) }
                            .onChange(of: scrollRequest) { _, _ in scroll(proxy) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CalendarSurface.background)
        .task(id: Calendar.current.startOfDay(for: anchor)) { await load() }
        .onAppear { if let start = draft?.start { anchor = start } }
    }

    // MARK: - Pieces

    /// The day and its arrows on the left, Next free time on the right, in the row where Event
    /// has its toolbar (the user's call: Event's items do not show here). Cancel and Send are the
    /// form's own, in its bottom bar.
    private var header: some View {
        HStack(spacing: 8) {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Move the meeting to the previous work day")
            Text((visibleDay ?? draft?.start ?? anchor).formatted(.dateTime.weekday(.wide).month(.wide).day()))
                // The toolbar's 13 pt, like Event's buttons and menus (the user's call).
                .font(.system(size: 13))
                .frame(minWidth: 150)
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Move the meeting to the next work day")
            if failed {
                Text("Free/busy could not be read.").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer()
            // Borderless like Event's toolbar items, not a bordered button.
            Button(action: nextFree) {
                // A label view, as Event's buttons have: a bare title draws grey when borderless.
                HStack(spacing: 4) {
                    Image(systemName: "forward.end")
                    Text("Next free time")
                }
            }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(loading)
        }
        .frame(height: EventEditorView.toolbarRowHeight)
        // The toolbar's own padding, so the row sits where Event's toolbar does.
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func sectionBand<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: Self.sectionHeight, maxHeight: Self.sectionHeight, alignment: .leading)
            .background(Color.primary.opacity(0.045))
    }

    private func nameCell(_ person: Row) -> some View {
        HStack(spacing: 6) {
            if let room = person.room {
                Toggle("", isOn: bookedBinding(room)).toggleStyle(FieldCheckboxStyle()).labelsHidden()
                    .help("Book this room")
            }
            // Every name starts at the left and is cut at the right (the user's call): for a
            // Persian name the right is its start, so the building goes and the room stays.
            DirectionalText(person.name, font: .system(size: 12), pinnedLeading: true,
                            truncation: TextDirection.firstStrong(in: person.name) == .rightToLeft ? .head : .tail)
                .foregroundStyle(person.room != nil && store.editor?.rooms.contains(person.room!) != true
                                 ? Color.secondary : Color.primary)
                .help(person.name)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: Self.nameWidth, height: Self.rowHeight, alignment: .leading)
        .overlay(alignment: .bottom) { rowLine }
    }

    private var rowLine: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
    }

    private var grid: some View {
        let timeline = timeline
        return VStack(alignment: .leading, spacing: 0) {
            // Each day's name over its hours, then the hours themselves.
            HStack(spacing: 0) {
                ForEach(Array(timeline.segments.enumerated()), id: \.offset) { index, segment in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(segment.dayStart.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Calendar.current.isDateInToday(segment.dayStart) ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                            .padding(.leading, 4)
                            .frame(height: Self.dayRowHeight)
                        HStack(spacing: 0) {
                            ForEach(Array(segment.hours), id: \.self) { hour in
                                Text(String(format: "%02d:00", hour)).id("d\(index)-h\(hour)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 3)
                                    .frame(width: Self.hourWidth, height: Self.hourRowHeight, alignment: .leading)
                            }
                        }
                    }
                    .frame(width: CGFloat(segment.hours.count) * Self.hourWidth, alignment: .leading)
                    .background(GeometryReader { box in
                        Color.clear.preference(key: DayEdgeKey.self,
                                               value: [segment.dayStart: box.frame(in: .named(Self.viewportSpace)).minX])
                    })
                }
            }
            ZStack(alignment: .topLeading) {
                hourLines(timeline)
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        switch line {
                        case .section: sectionBand { Color.clear }
                        case .row(let person): row(for: person.address, timeline: timeline)
                        }
                    }
                }
                meetingBand(timeline)
                if loading { ProgressView().controlSize(.small).padding(4) }
            }
            .frame(width: timeline.width)
            .coordinateSpace(name: Self.gridSpace)
            .contentShape(Rectangle())
            .onTapGesture { location in moveMeeting(toX: location.x, timeline: timeline) }
        }
        .padding(.trailing, 12)
    }

    private func row(for address: String, timeline: ScheduleTimeline) -> some View {
        let entry = blocks[address.lowercased()]
        let list: [BusyBlock] = (entry ?? nil) ?? []
        return ZStack(alignment: .topLeading) {
            if case .some(.none) = entry {
                Text("No information").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(height: Self.rowHeight).padding(.leading, 6)
            }
            ForEach(Array(list.flatMap { block in timeline.spans(block.start, block.end).map { (block, $0) } }.enumerated()),
                    id: \.offset) { _, piece in
                let (block, frame) = piece
                Group {
                    Image(nsImage: ShowAsSwatch.image(Self.state(block.type), width: max(frame.width, 4), height: Self.rowHeight - 5))
                        // Who booked it, or what it is, where the server says (a room's
                        // bookings carry the organizer's name), cut to the block.
                        .overlay(alignment: .leading) {
                            if let title = Self.title(of: block), frame.width > 24 {
                                Text(title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Self.state(block.type) == .away ? Color.white : Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 5)
                                    .frame(width: frame.width, alignment: .leading)
                            }
                        }
                        .offset(x: frame.x, y: 2)
                        .help(Self.tooltip(for: block))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) { rowLine }
    }

    /// A line on every hour, a fainter one on every half hour, a darker one where a day begins.
    private func hourLines(_ timeline: ScheduleTimeline) -> some View {
        Canvas { context, size in
            for segment in timeline.segments {
                for index in 0...segment.hours.count {
                    let x = segment.x + CGFloat(index) * Self.hourWidth
                    let dayEdge = index == 0
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                 with: .color(.primary.opacity(dayEdge ? 0.28 : 0.09)))
                    if index < segment.hours.count {
                        context.fill(Path(CGRect(x: x + Self.hourWidth / 2, y: 0, width: 1, height: size.height)),
                                     with: .color(.primary.opacity(0.04)))
                    }
                }
            }
        }
        .frame(height: linesHeight)
        .allowsHitTesting(false)
    }

    /// The meeting across the days it shows on, usually one piece. The first piece's left edge
    /// and the last one's right edge resize it; anywhere else moves it.
    @ViewBuilder
    private func meetingBand(_ timeline: ScheduleTimeline) -> some View {
        if let draft {
            let pieces = timeline.spans(draft.start, draft.end)
            ForEach(Array(pieces.enumerated()), id: \.offset) { index, frame in
                let isFirst = index == 0, isLast = index == pieces.count - 1
                let partAt: (CGFloat) -> BandPart = { x in
                    switch Self.part(at: x, width: frame.width) {
                    case .start: return isFirst ? .start : .move
                    case .end: return isLast ? .end : .move
                    case .move: return .move
                    }
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: frame.width, height: linesHeight)
                    .contentShape(Rectangle())
                    // Picked up with the hand and moved sideways, or resized by either edge, in
                    // 15-minute steps (the user's call). The cursor is set on every move rather
                    // than pushed, so the edges and the middle never unbalance it.
                    .onContinuousHover { phase in
                        guard dragOrigin == nil else { return }
                        switch phase {
                        case .active(let point): Self.cursor(for: partAt(point.x)).set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
                    // Measured in the grid's space: the band's own moves with it, so the drag
                    // shrank as the band followed the hand.
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.gridSpace))
                        .onChanged { value in
                            if dragOrigin == nil {
                                dragTimeline = timeline
                                dragOrigin = (draft.start, draft.end, partAt(value.startLocation.x - frame.x))
                            }
                            guard let origin = dragOrigin, let held = dragTimeline else { return }
                            Self.cursor(for: origin.part, dragging: true).set()
                            let shortest: TimeInterval = 15 * 60
                            switch origin.part {
                            case .move:
                                if let x = held.x(for: origin.start), let moved = held.date(atX: x + value.translation.width) {
                                    store.editor?.startKeepingDuration = ScheduleTimeline.snapped(moved)
                                }
                            case .start:
                                if let x = held.x(for: origin.start), let moved = held.date(atX: x + value.translation.width) {
                                    store.editor?.start = min(ScheduleTimeline.snapped(moved), origin.end.addingTimeInterval(-shortest))
                                }
                            case .end:
                                if let x = held.x(for: origin.end, preferEnd: true),
                                   let moved = held.date(atX: x + value.translation.width, preferEnd: true) {
                                    store.editor?.end = max(ScheduleTimeline.snapped(moved), origin.start.addingTimeInterval(shortest))
                                }
                            }
                        }
                        .onEnded { value in
                            dragOrigin = nil
                            dragTimeline = nil
                            // Let go outside the band, the arrow: no hover end will come to reset it.
                            let x = value.location.x - frame.x
                            let inside = (0...frame.width).contains(x) && (0...linesHeight).contains(value.location.y)
                            (inside ? Self.cursor(for: partAt(x)) : NSCursor.arrow).set()
                        })
                    .offset(x: frame.x)
                    .help("Drag to move the meeting, or drag an edge to change its length")
            }
        }
    }

    /// Which part of the band a point falls on: 6 pt at each edge resize it, less on a short one.
    static func part(at x: CGFloat, width: CGFloat) -> BandPart {
        let edge = min(6, width / 4)
        if x <= edge { return .start }
        if x >= width - edge { return .end }
        return .move
    }

    static func cursor(for part: BandPart, dragging: Bool = false) -> NSCursor {
        switch part {
        case .move: return dragging ? .closedHand : .openHand
        case .start, .end: return .resizeLeftRight
        }
    }

    /// The Show as menu's swatches, in its order, for the form's bottom bar.
    struct Legend: View {
        var body: some View {
            HStack(spacing: 12) {
                ForEach([EventDraft.ShowAs.elsewhere, .tentative, .busy, .away], id: \.self) { state in
                    HStack(spacing: 4) {
                        Image(nsImage: ShowAsSwatch.image(state, size: 13))
                        Text(state.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Doing

    /// To the hour before the meeting, on its day in the strip.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let draft else { return }
        let timeline = timeline
        guard let index = timeline.segments.firstIndex(where: { draft.start < $0.end && draft.end > $0.start })
                ?? timeline.segments.firstIndex(where: { $0.start >= draft.start }) else { return }
        let segment = timeline.segments[index]
        let hour = min(max(Calendar.current.component(.hour, from: draft.start) - 1, segment.hours.lowerBound),
                       segment.hours.upperBound - 1)
        DispatchQueue.main.async { proxy.scrollTo("d\(index)-h\(hour)", anchor: .leading) }
    }

    private func load() async {
        loading = true
        failed = false
        let found = await store.busyBlocks(for: people.map(\.address), from: stripStart, days: Self.stripDays)
        blocks = found ?? [:]
        failed = found == nil
        loading = false
    }

    /// The meeting to the previous or next work day at the same time, and the view with it. Past
    /// the strip's ends the strip moves to the meeting's new day.
    private func shiftDay(_ step: Int) {
        guard let draft else { return }
        let calendar = Calendar.current
        let workDays = Keys.calendarWorkDays()
        var moved = draft.start
        for _ in 0..<14 {
            moved = calendar.date(byAdding: .day, value: step, to: moved) ?? moved
            if workDays.contains(calendar.component(.weekday, from: moved)) { break }
        }
        store.editor?.startKeepingDuration = moved
        let stripEnd = calendar.date(byAdding: .day, value: Self.stripDays, to: stripStart) ?? stripStart
        if moved < stripStart || moved >= stripEnd { anchor = moved }
        scrollRequest += 1
    }

    private func moveMeeting(toX x: CGFloat, timeline: ScheduleTimeline) {
        // A click on the band itself is the start of a drag, not a new time.
        if let draft, timeline.spans(draft.start, draft.end).contains(where: { x >= $0.x && x <= $0.x + $0.width }) { return }
        guard let date = timeline.date(atX: x) else { return }
        store.editor?.startKeepingDuration = ScheduleTimeline.snapped(date, minutes: 30, down: true)
    }

    /// The first half hour from the meeting's start, through the strip's work hours, that nobody
    /// known is busy for the meeting's length and that ends inside the same day's hours.
    private func nextFree() {
        guard let draft else { return }
        if let found = timeline.nextFree(from: draft.start, length: draft.duration,
                                         busy: blocks.values.compactMap { $0 }.flatMap { $0 }) {
            store.editor?.startKeepingDuration = found
            scrollRequest += 1
        }
    }

    /// The block's words: its subject, or "Private" for a private one; nil when the server gave
    /// times only.
    static func title(of block: BusyBlock) -> String? {
        if block.isPrivate { return "Private" }
        return block.subject
    }

    /// Everything the server said about a block: state and times, then subject, place, repeats.
    static func tooltip(for block: BusyBlock) -> String {
        let minutes = Int(block.end.timeIntervalSince(block.start) / 60)
        let length = minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
        var lines = ["\(label(block.type)), \(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened)) (\(length))"]
        if let title = title(of: block) { lines.append(title) }
        if let location = block.location, !block.isPrivate { lines.append(location) }
        if block.isRecurring { lines.append("Repeats") }
        return lines.joined(separator: "\n")
    }

    /// A free/busy type as the Show as menu knows it; anything unknown reads as busy.
    static func state(_ type: String) -> EventDraft.ShowAs {
        EventDraft.ShowAs(rawValue: type) ?? .busy
    }

    static func label(_ type: String) -> String {
        switch type {
        case "OOF": return "Away"
        case "WorkingElsewhere": return "Working elsewhere"
        default: return type
        }
    }
}

/// Each shown day's left edge in the viewport, for the header's date.
private struct DayEdgeKey: PreferenceKey {
    static let defaultValue: [Date: CGFloat] = [:]
    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Schedule's strip: the days around the meeting side by side, only the work days and each only
/// its work hours, so nothing empty sits between one working day and the next. The meeting's own
/// days always show, stretched to take it in, even on a day off.
struct ScheduleTimeline: Equatable {
    struct Segment: Equatable {
        let dayStart: Date
        let hours: Range<Int>
        let x: CGFloat
        var start: Date { dayStart.addingTimeInterval(TimeInterval(hours.lowerBound * 3600)) }
        var end: Date { dayStart.addingTimeInterval(TimeInterval(hours.upperBound * 3600)) }
    }

    let segments: [Segment]
    let hourWidth: CGFloat

    var width: CGFloat {
        guard let last = segments.last else { return 0 }
        return last.x + CGFloat(last.hours.count) * hourWidth
    }

    init(first: Date, days: Int, workDays: Set<Int>, workHours: ClosedRange<Int>,
         meeting: (start: Date, end: Date)?, hourWidth: CGFloat, calendar: Calendar = .current) {
        self.hourWidth = hourWidth
        var segments: [Segment] = []
        var x: CGFloat = 0
        let firstDay = calendar.startOfDay(for: first)
        for offset in 0..<max(days, 1) {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            var from = workHours.lowerBound, to = workHours.upperBound
            let touched = meeting.map { $0.start < dayEnd && $0.end > dayStart } ?? false
            if touched, let meeting {
                from = min(from, Int(max(meeting.start, dayStart).timeIntervalSince(dayStart) / 3600))
                to = max(to, Int((min(meeting.end, dayEnd).timeIntervalSince(dayStart) / 3600).rounded(.up)))
            }
            guard touched || workDays.contains(calendar.component(.weekday, from: dayStart)) else { continue }
            let hours = max(0, from)..<min(24, max(to, from + 1))
            segments.append(Segment(dayStart: dayStart, hours: hours, x: x))
            x += CGFloat(hours.count) * hourWidth
        }
        self.segments = segments
    }

    /// Where a moment falls on the strip, nil in hidden time. At the seam between two days,
    /// `preferEnd` takes the earlier day's end rather than the later one's start.
    func x(for date: Date, preferEnd: Bool = false) -> CGFloat? {
        let ordered = preferEnd ? segments.reversed() : segments
        for segment in ordered where date >= segment.start && date <= segment.end {
            if preferEnd, date == segment.start, segment != segments.first { continue }
            return segment.x + CGFloat(date.timeIntervalSince(segment.start) / 3600) * hourWidth
        }
        return nil
    }

    /// The moment at a point, held to the strip's ends.
    func date(atX x: CGFloat, preferEnd: Bool = false) -> Date? {
        guard let first = segments.first, let last = segments.last else { return nil }
        if x <= 0 { return first.start }
        for segment in segments {
            let right = segment.x + CGFloat(segment.hours.count) * hourWidth
            if x < right || (preferEnd && x <= right) {
                return segment.start.addingTimeInterval(TimeInterval((x - segment.x) / hourWidth * 3600))
            }
        }
        return last.end
    }

    /// A range on the strip, one piece per day it shows on, clipped to the hours shown.
    func spans(_ start: Date, _ end: Date) -> [(x: CGFloat, width: CGFloat)] {
        segments.compactMap { segment in
            let lo = max(start, segment.start), hi = min(end, segment.end)
            guard hi > lo else { return nil }
            return (segment.x + CGFloat(lo.timeIntervalSince(segment.start) / 3600) * hourWidth,
                    CGFloat(hi.timeIntervalSince(lo) / 3600) * hourWidth)
        }
    }

    /// The first half hour from `from` on, inside one day's shown hours with room for `length`,
    /// that no busy block overlaps.
    func nextFree(from: Date, length: TimeInterval, busy: [BusyBlock]) -> Date? {
        for segment in segments where segment.end > from {
            var candidate = max(ScheduleTimeline.snapped(from, minutes: 30, up: true), segment.start)
            while candidate.addingTimeInterval(length) <= segment.end {
                let end = candidate.addingTimeInterval(length)
                if !busy.contains(where: { $0.start < end && $0.end > candidate }) { return candidate }
                candidate = candidate.addingTimeInterval(1800)
            }
        }
        return nil
    }

    /// A moment on a whole number of minutes from its day's start: nearest, or down, or up.
    static func snapped(_ date: Date, minutes: Int = 15, down: Bool = false, up: Bool = false,
                        calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let steps = date.timeIntervalSince(dayStart) / TimeInterval(minutes * 60)
        let rounded = down ? steps.rounded(.down) : up ? steps.rounded(.up) : steps.rounded()
        return dayStart.addingTimeInterval(rounded * TimeInterval(minutes * 60))
    }
}
