import SwiftUI

/// Outlook's Scheduling Assistant (the user's request, 2026-09-25): everyone on the event, you
/// first, then the people and rooms invited, one row each across the day's hours with their busy
/// blocks from the server's free/busy (`GetUserAvailability`). The meeting is the accent band; a
/// click on the grid moves it there, in half hours, keeping its length. Next free time finds the
/// first slot everyone has open that day. Nothing is kept: the blocks live while the sheet is up.
struct SchedulingAssistant: View {
    @Bindable var store: CalendarStore
    let onClose: () -> Void

    @State private var day = Date()
    @State private var blocks: [String: [BusyBlock]?] = [:]
    @State private var loading = true
    @State private var failed = false

    // Dense, after Outlook's: short rows, thin lines, a band per section.
    private static let hourWidth: CGFloat = 48
    private static let rowHeight: CGFloat = 24
    private static let sectionHeight: CGFloat = 20
    private static let timelineHeight: CGFloat = 20
    private static let nameWidth: CGFloat = 200
    /// 07:00 to 21:00, stretched to take in the meeting when it falls outside.
    private var hours: Range<Int> {
        guard let draft else { return 7..<21 }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let from = Int(draft.start.timeIntervalSince(dayStart) / 3600)
        let to = Int((draft.end.timeIntervalSince(dayStart) / 3600).rounded(.up))
        return max(0, min(7, from))..<min(24, max(21, to))
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
                            .onAppear { scroll(proxy) }
                            .onChange(of: draft?.start) { _, _ in scroll(proxy) }
                    }
                }
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(width: 900, height: 460)
        .background(CalendarSurface.background)
        .task(id: Calendar.current.startOfDay(for: day)) { await load() }
        .onAppear { if let start = draft?.start { day = start } }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Text("Scheduling Assistant").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous day")
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 170)
            Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Next day")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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
            DirectionalText(person.name, font: .system(size: 12))
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
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.color(block.type))
                        .frame(width: max(frame.width - 1, 2), height: Self.rowHeight - 7)
                        .offset(x: frame.x + 1, y: 3)
                        .help("\(Self.label(block.type)), \(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened))")
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
                .offset(x: frame.x)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            legend("Busy", "Busy")
            legend("Tentative", "Tentative")
            legend("OOF", "Away")
            legend("WorkingElsewhere", "Working elsewhere")
            if failed {
                Text("Free/busy could not be read.").font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer()
            Button("Next free time", action: nextFree)
                .disabled(loading)
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func legend(_ type: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Self.color(type)).frame(width: 10, height: 10)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
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

    static func color(_ type: String) -> Color {
        switch type {
        case "Tentative": return Color(.sRGB, red: 0.72, green: 0.8, blue: 0.93).opacity(0.55)
        case "OOF": return Color(.sRGB, red: 0.55, green: 0.27, blue: 0.5)
        case "WorkingElsewhere": return Color.teal.opacity(0.6)
        default: return Color(.sRGB, red: 0.45, green: 0.6, blue: 0.85)
        }
    }

    static func label(_ type: String) -> String {
        switch type {
        case "OOF": return "Away"
        case "WorkingElsewhere": return "Working elsewhere"
        default: return type
        }
    }
}
