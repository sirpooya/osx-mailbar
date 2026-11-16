import SwiftUI

/// The two widgets' faces (M26), shared by the widget extension and the app's DEBUG preview
/// window (`--widget-preview`), so a screenshot shows exactly what the widget draws. The system
/// adds the widget's margins and background; these views fill what is left.
enum AgendaWidgetSize {
    case small, medium, large
}

/// Up Next: the next one to three events today, with the time, the place and Join.
struct UpNextWidgetView: View {
    let agenda: WidgetAgenda?
    let now: Date
    let size: AgendaWidgetSize

    var body: some View {
        if let agenda, agenda.isCurrent(at: now) {
            let next = agenda.upNext(at: now, limit: size == .small ? 1 : 3)
            if next.isEmpty {
                WidgetEmptyView(title: "Up Next", message: "Nothing else today.", symbol: "checkmark.circle")
            } else if size == .small, let first = next.first {
                small(first, agenda: agenda)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: "Up Next", detail: agenda.dayTitle(now))
                    ForEach(next) { event in
                        WidgetEventRow(event: event, agenda: agenda, now: now, showsTime: false)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            WidgetEmptyView(title: "Up Next", message: "Open Mailbar to load today.", symbol: "calendar")
        }
    }

    private func small(_ event: WidgetAgenda.Event, agenda: WidgetAgenda) -> some View {
        let more = agenda.upNext(at: now, limit: 99).count - 1
        return VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(title: "Up Next", detail: nil)
            Spacer(minLength: 4)
            Text(agenda.relative(event, now: now))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            WidgetText(event.title, font: .system(size: 14, weight: .semibold), lines: 3)
            Text(agenda.span(event))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !event.location.isEmpty {
                WidgetText(event.location, font: .system(size: 11), lines: 1)
                    .foregroundStyle(.secondary)
            }
            if more > 0 {
                Text("+\(more) more today")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// Agenda: what is left of today, all-day events first.
struct AgendaWidgetView: View {
    let agenda: WidgetAgenda?
    let now: Date
    let size: AgendaWidgetSize

    var body: some View {
        if let agenda, agenda.isCurrent(at: now) {
            let events = agenda.remaining(at: now)
            let limit = size == .large ? 7 : 3
            if events.isEmpty {
                WidgetEmptyView(title: "Today", message: "Nothing else today.", symbol: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: "Today", detail: agenda.dayTitle(now))
                    ForEach(events.prefix(limit)) { event in
                        WidgetEventRow(event: event, agenda: agenda, now: now, showsTime: true)
                    }
                    Spacer(minLength: 0)
                    if events.count > limit {
                        Text("+\(events.count - limit) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            WidgetEmptyView(title: "Today", message: "Open Mailbar to load today.", symbol: "calendar")
        }
    }
}

// MARK: - Pieces

private struct WidgetHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One event: a bar in the accent, the title over the time and place, Join on the right.
private struct WidgetEventRow: View {
    let event: WidgetAgenda.Event
    let agenda: WidgetAgenda
    let now: Date
    /// The Agenda puts the start in its own column; Up Next says how soon instead.
    let showsTime: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showsTime {
                Text(agenda.isAllDay(event) ? "All day" : agenda.timeText(event.start))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                WidgetText(event.title, font: .system(size: 12, weight: .semibold), lines: 1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let join = event.joinURL {
                Link(destination: join) {
                    Text("Join")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
            }
        }
        .frame(height: 30)
    }

    /// "in 25 min, Room Blue" or "09:30 to 10:00, Room Blue".
    private var detail: String {
        let time = showsTime ? (agenda.isAllDay(event) ? "" : agenda.span(event)) : "\(agenda.relative(event, now: now)), \(agenda.span(event))"
        return [time, event.location].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private struct WidgetEmptyView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: title, detail: nil)
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A title or place in its own direction: a Persian one starts at the right.
private struct WidgetText: View {
    let text: String
    let font: Font
    let lines: Int

    init(_ text: String, font: Font, lines: Int) {
        self.text = text
        self.font = font
        self.lines = lines
    }

    var body: some View {
        let rtl = TextDirection.firstStrong(in: text) == .rightToLeft
        Text(text)
            .font(font)
            .lineLimit(lines)
            .multilineTextAlignment(rtl ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
    }
}
