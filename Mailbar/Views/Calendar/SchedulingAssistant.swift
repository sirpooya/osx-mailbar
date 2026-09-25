import SwiftUI

/// The event form's Schedule view, Outlook's Scheduling Assistant (the user's request,
/// 2026-09-25), a segment beside Event in the form, never a sheet of its own: everyone on the event, you
/// first, then the people and rooms invited, one row each across the day's hours with their busy
/// blocks from the server's free/busy (`GetUserAvailability`). The meeting is the accent band; a
/// click on the grid moves it there, in half hours, keeping its length. Next free time finds the
/// first slot everyone has open that day. Nothing is kept: the blocks live while the sheet is up.
struct SchedulingAssistant: View {
    @Bindable var store: CalendarStore

    @State private var day = Date()
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
    private static let timelineHeight: CGFloat = 20
    /// Wide enough for a room's full name ("building | floor | room"), the user's call.
    private static let nameWidth: CGFloat = 270
    /// The whole day, always. A range stretched around the meeting shifted the grid under the
    /// hand while the band was dragged across an hour (the user's recording); the view scrolls
    /// to the meeting instead.
    private let hours = 0..<24
    private static let gridSpace = "scheduleGrid"

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
                            .onAppear { scroll(proxy) }
                            // Not while the band is dragged, or the grid would run from the hand.
                            .onChange(of: draft?.start) { _, _ in if dragOrigin == nil { scroll(proxy) } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CalendarSurface.background)
        .task(id: Calendar.current.startOfDay(for: day)) { await load() }
        .onAppear { if let start = draft?.start { day = start } }
    }

    // MARK: - Pieces

    /// The day and its arrows on the left, Next free time on the right, in the row where Event
    /// has its toolbar (the user's call: Event's items do not show here). Cancel and Send are the
    /// form's own, in its bottom bar.
    private var header: some View {
        HStack(spacing: 8) {
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous day")
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                // The toolbar's 13 pt, like Event's buttons and menus (the user's call).
                .font(.system(size: 13))
                .frame(minWidth: 150)
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Next day")
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
            DirectionalText(person.name, font: .system(size: 12), truncation: person.room != nil ? .head : .tail)
                .foregroundStyle(person.room != nil && store.editor?.rooms.contains(person.room!) != true
                                 ? Color.secondary : Color.primary)
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
        let width = CGFloat(hours.count) * Self.hourWidth
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(hours), id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).id("hour-\(hour)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.hourWidth, height: Self.timelineHeight, alignment: .leading)
                        .padding(.leading, 3)
                }
            }
            ZStack(alignment: .topLeading) {
                hourLines
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        switch line {
                        case .section: sectionBand { Color.clear }
                        case .row(let person): row(for: person.address, dayStart: dayStart)
                        }
                    }
                }
                meetingBand(dayStart: dayStart)
                if loading { ProgressView().controlSize(.small).padding(4) }
            }
            .frame(width: width)
            .coordinateSpace(name: Self.gridSpace)
            .contentShape(Rectangle())
            .onTapGesture { location in moveMeeting(toX: location.x, dayStart: dayStart) }
        }
        .padding(.trailing, 12)
    }

    private func row(for address: String, dayStart: Date) -> some View {
        let entry = blocks[address.lowercased()]
        let list: [BusyBlock] = (entry ?? nil) ?? []
        return ZStack(alignment: .topLeading) {
            if case .some(.none) = entry {
                Text("No information").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(height: Self.rowHeight).padding(.leading, 6)
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, block in
                if let frame = span(block.start, block.end, dayStart: dayStart) {
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

    /// A line on every hour, a fainter one on every half hour.
    private var hourLines: some View {
        Canvas { context, size in
            for index in 0...hours.count {
                let x = CGFloat(index) * Self.hourWidth
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.09)))
                if index < hours.count {
                    context.fill(Path(CGRect(x: x + Self.hourWidth / 2, y: 0, width: 1, height: size.height)),
                                 with: .color(.primary.opacity(0.04)))
                }
            }
        }
        .frame(height: linesHeight)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func meetingBand(dayStart: Date) -> some View {
        if let draft, let frame = span(draft.start, draft.end, dayStart: dayStart) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: frame.width, height: linesHeight)
                .contentShape(Rectangle())
                // Picked up with the hand and moved sideways, or resized by either edge, in
                // 15-minute steps within the day shown (the user's call). The cursor is set on
                // every move rather than pushed, so the edges and the middle never unbalance it.
                .onContinuousHover { phase in
                    guard dragOrigin == nil else { return }
                    switch phase {
                    case .active(let point): Self.cursor(for: Self.part(at: point.x, width: frame.width)).set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
                // Measured in the grid's space: the band's own moves with it, so the drag shrank
                // as the band followed the hand.
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.gridSpace))
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = (draft.start, draft.end, Self.part(at: value.startLocation.x - frame.x, width: frame.width))
                        }
                        guard let origin = dragOrigin else { return }
                        Self.cursor(for: origin.part, dragging: true).set()
                        let step = (Double(value.translation.width / Self.hourWidth) * 60 / 15).rounded() * 15 * 60
                        let dayEnd = dayStart.addingTimeInterval(86_400)
                        let shortest: TimeInterval = 15 * 60
                        switch origin.part {
                        case .move:
                            let length = origin.end.timeIntervalSince(origin.start)
                            let moved = origin.start.addingTimeInterval(step)
                            store.editor?.startKeepingDuration = min(max(moved, dayStart), max(dayEnd.addingTimeInterval(-length), dayStart))
                        case .start:
                            store.editor?.start = min(max(origin.start.addingTimeInterval(step), dayStart), origin.end.addingTimeInterval(-shortest))
                        case .end:
                            store.editor?.end = max(min(origin.end.addingTimeInterval(step), dayEnd), origin.start.addingTimeInterval(shortest))
                        }
                    }
                    .onEnded { value in
                        dragOrigin = nil
                        // Let go outside the band, the arrow: no hover end will come to reset it.
                        let x = value.location.x - frame.x
                        let inside = (0...frame.width).contains(x) && (0...linesHeight).contains(value.location.y)
                        (inside ? Self.cursor(for: Self.part(at: x, width: frame.width)) : NSCursor.arrow).set()
                    })
                .offset(x: frame.x)
                .help("Drag to move the meeting, or drag an edge to change its length")
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

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let draft else { return }
        let hour = max(Calendar.current.component(.hour, from: draft.start) - 1, hours.lowerBound)
        DispatchQueue.main.async { proxy.scrollTo("hour-\(hour)", anchor: .leading) }
    }

    private func load() async {
        loading = true
        failed = false
        let found = await store.busyBlocks(for: people.map(\.address), on: day)
        blocks = found ?? [:]
        failed = found == nil
        loading = false
    }

    /// Moving to another day keeps the meeting's time of day and moves it with the view.
    private func shiftDay(_ step: Int) {
        guard let draft else { return }
        let calendar = Calendar.current
        day = calendar.date(byAdding: .day, value: step, to: day) ?? day
        store.editor?.startKeepingDuration = calendar.date(byAdding: .day, value: step, to: draft.start) ?? draft.start
    }

    private func moveMeeting(toX x: CGFloat, dayStart: Date) {
        // A click on the band itself is the start of a drag, not a new time.
        if let draft, let frame = span(draft.start, draft.end, dayStart: dayStart),
           x >= frame.x, x <= frame.x + frame.width { return }
        let minutes = (Double(hours.lowerBound) + Double(x / Self.hourWidth)) * 60
        let rounded = (minutes / 30).rounded(.down) * 30
        store.editor?.startKeepingDuration = dayStart.addingTimeInterval(rounded * 60)
    }

    /// The first half hour from the meeting's start, then through the day, that nobody known is
    /// busy for the meeting's length.
    private func nextFree() {
        guard let draft else { return }
        let length = draft.duration
        let busy = blocks.values.compactMap { $0 }.flatMap { $0 }
        let dayStart = Calendar.current.startOfDay(for: day)
        let last = dayStart.addingTimeInterval(TimeInterval(hours.upperBound * 3600))
        var candidate = max(draft.start, dayStart.addingTimeInterval(TimeInterval(hours.lowerBound * 3600)))
        while candidate.addingTimeInterval(length) <= last {
            let end = candidate.addingTimeInterval(length)
            if !busy.contains(where: { $0.start < end && $0.end > candidate }) {
                store.editor?.startKeepingDuration = candidate
                return
            }
            candidate = candidate.addingTimeInterval(1800)
        }
    }

    /// Where a time range falls on the grid, clipped to the hours shown.
    private func span(_ start: Date, _ end: Date, dayStart: Date) -> (x: CGFloat, width: CGFloat)? {
        let from = CGFloat(start.timeIntervalSince(dayStart) / 3600) - CGFloat(hours.lowerBound)
        let to = CGFloat(end.timeIntervalSince(dayStart) / 3600) - CGFloat(hours.lowerBound)
        let lo = max(from, 0), hi = min(to, CGFloat(hours.count))
        guard hi > lo else { return nil }
        return (lo * Self.hourWidth, (hi - lo) * Self.hourWidth)
    }

    /// The block's words: its subject, or "Private" for a private one; nil when the server gave
    /// times only.
    static func title(of block: BusyBlock) -> String? {
        if block.isPrivate { return "Private" }
        return block.subject
    }

    /// Everything the server said about a block: state and times, then subject, place, repeats.
    static func tooltip(for block: BusyBlock) -> String {
        var lines = ["\(label(block.type)), \(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened))"]
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
