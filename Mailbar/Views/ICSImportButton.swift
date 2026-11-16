import SwiftUI

/// "Add to Calendar" under a message's files when one is an .ics or .vcs (2026-11-16): the file
/// is read (bytes in memory only), its events are shown, and Add writes each as a plain
/// appointment on the user's calendar (`CreateItem`, `SendToNone`): nobody is invited or told.
struct ICSImportButton: View {
    let files: [FileAttachment]
    let accountID: UUID
    @Bindable var store: MailStore

    @State private var open = false

    private var calendarFiles: [FileAttachment] {
        files.filter { ICalendar.isCalendarFile(name: $0.name, contentType: $0.contentType) }
    }

    var body: some View {
        if let file = calendarFiles.first {
            Button { open = true } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .modifier(TonalCapsule())
            }
            .buttonStyle(.plain)
            .help("Add the events in \(file.name) to your calendar")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ICSImportSheet(file: file, accountID: accountID, store: store, onClose: { open = false })
            }
        }
    }
}

/// What the file holds and the Add button. Fetches the file when it opens.
struct ICSImportSheet: View {
    let file: FileAttachment?
    let accountID: UUID
    @Bindable var store: MailStore
    let onClose: () -> Void
    /// For screenshots: events already parsed, nothing fetched.
    var preloaded: [ICalendar.Event]? = nil

    enum Phase: Equatable {
        case loading
        case ready([ICalendar.Event])
        case adding
        case added(Int)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to Calendar").font(.system(size: 13, weight: .semibold))
            switch phase {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(file?.name ?? "the file")").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .ready(let events):
                if events.isEmpty {
                    Text("The file holds no events this can read.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(events) { row($0) }
                    Text("Added as your own appointment; nobody is invited or told.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .adding:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Adding").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .added(let count):
                Label(count == 1 ? "Added to your calendar." : "\(count) events added to your calendar.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .added = phase {
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                    if case .ready(let events) = phase, !events.isEmpty {
                        Button(events.count == 1 ? "Add" : "Add \(events.count)") { Task { await add(events) } }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .task { await load() }
    }

    private func row(_ event: ICalendar.Event) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.repeatPattern == nil ? "calendar" : "arrow.2.squarepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                DirectionalText(event.summary.isEmpty ? "(No title)" : event.summary,
                                font: .system(size: 12, weight: .medium), pinnedLeading: true)
                Text(MeetingText.when(start: event.start, end: event.end, allDay: event.isAllDay))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let pattern = event.repeatPattern {
                    Text(pattern.label(start: event.start, workDays: Keys.calendarWorkDays()) + Self.endText(event.repeatEnd))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !event.location.isEmpty {
                    DirectionalText(event.location, font: .system(size: 11), pinnedLeading: true, truncation: .head)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// ", 3 times" or ", until Dec 31" after the repeat's words.
    static func endText(_ end: RepeatEnd) -> String {
        switch end {
        case .never: return ""
        case .after(let count): return count == 1 ? ", once" : ", \(count) times"
        case .on(let day): return ", until \(day.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
    }

    private func load() async {
        if let preloaded {
            phase = .ready(preloaded)
            return
        }
        guard let file, let (url, credential) = store.connection(for: accountID) else {
            phase = .failed("The password for this account is missing. Enter it in Settings.")
            return
        }
        do {
            let data = try await store.client.attachmentContent(id: file.id, at: url, credential: credential)
            phase = .ready(ICalendar.events(in: data))
        } catch let error as EWSError {
            phase = .failed(error.message(host: store.accounts.account(accountID)?.host ?? "The server"))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func add(_ events: [ICalendar.Event]) async {
        guard let (url, credential) = store.connection(for: accountID) else { return }
        phase = .adding
        do {
            for event in events {
                try await store.client.createEvent(ICalendar.draft(event, accountID: accountID), at: url, credential: credential)
            }
            phase = .added(events.count)
        } catch let error as EWSError {
            phase = .failed(error.message(host: store.accounts.account(accountID)?.host ?? "The server"))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
