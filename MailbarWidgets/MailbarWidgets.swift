import SwiftUI
import WidgetKit

/// Mailbar's widgets (M26): Up Next and Agenda, both from the one small file the app writes into
/// the App Group container (`WidgetAgenda`). The extension never talks to the mail server and
/// holds no credentials; with no file, or yesterday's, it says to open Mailbar.
@main
struct MailbarWidgets: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        AgendaWidget()
    }
}

struct AgendaEntry: TimelineEntry {
    let date: Date
    let agenda: WidgetAgenda?
}

struct AgendaProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: Date(), agenda: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgendaEntry) -> Void) {
        completion(AgendaEntry(date: Date(), agenda: WidgetAgenda.read()))
    }

    /// One entry now and one at each start and end left today, so an event turns "Now" and then
    /// leaves on time without the app running; the app also reloads the timelines when it writes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AgendaEntry>) -> Void) {
        let now = Date()
        let agenda = WidgetAgenda.read()
        let moments = agenda?.refreshDates(after: now) ?? []
        let entries = [AgendaEntry(date: now, agenda: agenda)] + moments.map { AgendaEntry(date: $0, agenda: agenda) }
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
        completion(Timeline(entries: entries, policy: .after(moments.last ?? next)))
    }
}

private extension WidgetFamily {
    var agendaSize: AgendaWidgetSize {
        switch self {
        case .systemSmall: return .small
        case .systemLarge, .systemExtraLarge: return .large
        default: return .medium
        }
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "in.pooya.mailbar.upnext", provider: AgendaProvider()) { entry in
            UpNextEntryView(entry: entry)
        }
        .configurationDisplayName("Up Next")
        .description("Your next events today, with Join for online meetings.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AgendaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "in.pooya.mailbar.agenda", provider: AgendaProvider()) { entry in
            AgendaEntryView(entry: entry)
        }
        .configurationDisplayName("Agenda")
        .description("What is left of today.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct UpNextEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    var body: some View {
        UpNextWidgetView(agenda: entry.agenda, now: entry.date, size: family.agendaSize)
            .containerBackground(.background, for: .widget)
            // The small widget is one tap target: it joins the meeting under way or about to start.
            .widgetURL(family == .systemSmall ? joinable : nil)
    }

    private var joinable: URL? {
        guard let first = entry.agenda?.upNext(at: entry.date, limit: 1).first,
              first.start.timeIntervalSince(entry.date) <= 15 * 60 else { return nil }
        return first.joinURL
    }
}

private struct AgendaEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgendaEntry

    var body: some View {
        AgendaWidgetView(agenda: entry.agenda, now: entry.date, size: family.agendaSize)
            .containerBackground(.background, for: .widget)
    }
}
