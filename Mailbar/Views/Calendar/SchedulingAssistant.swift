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

    private static let hourWidth: CGFloat = 56
    private static let rowHeight: CGFloat = 40
    private static let nameWidth: CGFloat = 180
    private let hours = 7..<21

    private var draft: EventDraft? { store.editor }

    /// You, then the people, then the rooms, as the invitation lists them.
    private var people: [(name: String, address: String, isRoom: Bool)] {
        var rows: [(String, String, Bool)] = []
        if let account = store.account, !account.email.isEmpty {
            rows.append((account.fullName.isEmpty ? account.email : account.fullName, account.email, false))
        }
        for person in draft?.people ?? [] { rows.append((person.display, person.address, false)) }
        for room in draft?.rooms ?? [] { rows.append((room.name, room.address, true)) }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 24)
                        ForEach(people, id: \.address) { person in
                            HStack(spacing: 6) {
                                Image(systemName: person.isRoom ? "building.2" : "person.crop.circle")
                                    .foregroundStyle(.secondary)
                                DirectionalText(person.name, font: .system(size: 12))
                            }
                            .frame(width: Self.nameWidth - 12, height: Self.rowHeight, alignment: .leading)
                            .padding(.leading, 12)
                        }
                    }
                    ScrollView(.horizontal) { grid }
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
        .padding(.vertical, 10)
    }

    private var grid: some View {
        let width = CGFloat(hours.count) * Self.hourWidth
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(hours), id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.hourWidth, height: 24, alignment: .leading)
                        .padding(.leading, 3)
                }
            }
            ZStack(alignment: .topLeading) {
                // Hour lines and the rows' grey wells.
                VStack(spacing: 0) {
                    ForEach(people, id: \.address) { person in
                        row(for: person.address, dayStart: dayStart)
                    }
                }
                meetingBand(dayStart: dayStart)
                if loading { ProgressView().controlSize(.small).padding(8) }
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
            HStack(spacing: 0) {
                ForEach(Array(hours), id: \.self) { _ in
                    Rectangle().fill(Color.primary.opacity(0.03))
                        .frame(width: Self.hourWidth - 1, height: Self.rowHeight - 6)
                        .padding(.trailing, 1)
                }
            }
            .padding(.vertical, 3)
            if case .some(.none) = entry {
                Text("No information").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(height: Self.rowHeight).padding(.leading, 6)
            }
            ForEach(Array(list.enumerated()), id: \.offset) { _, block in
                if let frame = span(block.start, block.end, dayStart: dayStart) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.color(block.type))
                        .frame(width: frame.width, height: Self.rowHeight - 10)
                        .offset(x: frame.x, y: 5)
                        .help("\(Self.label(block.type)), \(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened))")
                }
            }
        }
        .frame(height: Self.rowHeight)
    }

    @ViewBuilder
    private func meetingBand(dayStart: Date) -> some View {
        if let draft, let frame = span(draft.start, draft.end, dayStart: dayStart) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: frame.width, height: CGFloat(people.count) * Self.rowHeight)
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
        .padding(.vertical, 10)
    }

    private func legend(_ type: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Self.color(type)).frame(width: 10, height: 10)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Doing

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
