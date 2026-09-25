import SwiftUI

/// The selected event, at the window's right edge: when, where, who, and the notes. The notes are
/// HTML and go through the reader's rules: no JavaScript, remote images blocked.
struct EventDetailPanel: View {
    @Bindable var store: CalendarStore

    @State private var note = ""
    @State private var confirmingDelete = false
    @State private var answering: CalendarSOAP.Answer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // Edit and delete: the user's own appointments and the meetings they organized.
                if store.canEditSelected {
                    Button("Edit") { store.startEditing() }
                        .disabled({ if case .loaded = store.detail { return false } else { return true } }())
                    Button(role: .destructive) { confirmingDelete = true } label: { Text("Delete") }
                }
                Spacer()
                Button { Task { await store.select(nil) } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if confirmingDelete, let event = store.selectedEvent {
                deleteConfirmation(event)
            }

            if let event = store.selectedEvent {
                summary(event)
                if store.canAnswerSelected { answerBar(event) }
            }

            switch store.detail {
            case .idle:
                Spacer()
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
                Spacer()
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).padding(14)
                Spacer()
            case .loaded(let detail):
                people(detail)
                if !detail.files.isEmpty, let account = store.account {
                    AttachmentStrip(files: detail.files, accountID: account.id, store: store.mail)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                if !detail.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider().opacity(0.6).padding(.top, 8)
                    MessageWebView(html: ReaderHTML.document(body: detail.html, images: [:], allowRemoteImages: false))
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }
            }
        }
        .background(CalendarSurface.background)
    }

    // MARK: - Delete (M16)

    private func deleteConfirmation(_ event: CalendarEvent) -> some View {
        let cancels = event.isMeeting && event.isOrganizer
        return VStack(alignment: .leading, spacing: 8) {
            Text(cancels ? "Cancel this meeting? Everyone invited is told." : "Delete this event?")
                .font(.system(size: 12))
            if event.isRecurring {
                Text("Only this occurrence.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Keep") { confirmingDelete = false }
                Button(cancels ? "Cancel Meeting" : "Delete", role: .destructive) {
                    confirmingDelete = false
                    Task { await store.deleteSelected() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.07)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Answer (M17)

    /// Accept, Tentative, Decline, with an optional note to the organizer. The current answer is
    /// the filled one.
    private func answerBar(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(CalendarSOAP.Answer.allCases, id: \.self) { answer in
                    let current = event.myResponse == answer.responseType
                    Button {
                        answering = answer
                        Task {
                            await store.answerSelected(answer, note: note)
                            note = ""
                            answering = nil
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if answering == answer { ProgressView().controlSize(.mini) }
                            Text(answer.label).font(.system(size: 12, weight: current ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(current ? Color.accentColor.opacity(0.2) : CalendarControl.fill))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(answering != nil)
                }
            }
            TextField("Add a note for the organizer (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func summary(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let charm = event.charm.flatMap(EventCharm.init) {
                    Image(systemName: charm.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(store.tint(for: event))
                        .help(charm.label)
                }
                DirectionalText(event.subject, font: .system(size: 17, weight: .semibold))
                    .strikethrough(event.isCancelled)
            }
            if event.isCancelled {
                Label("Cancelled", systemImage: "xmark.circle").font(.system(size: 12)).foregroundStyle(.red)
            }
            Label(timeText(event), systemImage: event.isRecurring ? "arrow.2.squarepath" : "clock")
                .font(.system(size: 12))
            if !event.location.isEmpty {
                Label { DirectionalText(event.location, font: .system(size: 12)) } icon: { Image(systemName: "mappin.and.ellipse") }
                    .font(.system(size: 12))
            }
            if !event.categories.isEmpty {
                HStack(spacing: 6) {
                    ForEach(event.categories, id: \.self) { name in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(store.categoryColor(name))
                                .frame(width: 10, height: 10)
                            Text(name).font(.system(size: 11))
                        }
                    }
                }
            }
            if event.isMeeting, !event.isOrganizer {
                Label(responseText(event.myResponse), systemImage: responseSymbol(event.myResponse))
                    .font(.system(size: 12))
                    .foregroundStyle(event.isTentative ? .orange : .secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func people(_ detail: EventDetail) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !detail.event.organizer.isEmpty {
                row(symbol: "person.crop.circle", title: detail.event.organizer, subtitle: "Organizer")
            }
            ForEach(detail.attendees) { person in
                row(symbol: responseSymbol(person.response), title: person.display,
                    subtitle: person.isOptional ? "Optional" : responseText(person.response))
            }
            ForEach(detail.rooms, id: \.self) { room in
                row(symbol: "building.2", title: room, subtitle: "Room")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func row(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            DirectionalText(title, font: .system(size: 12))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize()
        }
    }

    private func timeText(_ event: CalendarEvent) -> String {
        let calendar = store.calendar
        let day = event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if event.isAllDay {
            let days = event.days(in: calendar)
            if days.count > 1, let last = days.last {
                return "\(day) to \(last.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), all day"
            }
            return "\(day), all day"
        }
        let from = event.start.formatted(date: .omitted, time: .shortened)
        let to = calendar.isDate(event.start, inSameDayAs: event.end)
            ? event.end.formatted(date: .omitted, time: .shortened)
            : event.end.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(day), \(from) to \(to)"
    }

    private func responseText(_ response: String) -> String {
        switch response {
        case "Accept": return "Accepted"
        case "Tentative": return "Tentative"
        case "Decline": return "Declined"
        case "Organizer": return "Organizer"
        case "NoResponseReceived": return "Not answered yet"
        default: return ""
        }
    }

    private func responseSymbol(_ response: String) -> String {
        switch response {
        case "Accept": return "checkmark.circle.fill"
        case "Tentative": return "questionmark.circle"
        case "Decline": return "xmark.circle"
        case "Organizer": return "person.crop.circle"
        default: return "circle.dashed"
        }
    }
}
