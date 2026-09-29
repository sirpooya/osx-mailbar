import SwiftUI

/// The selected event, at the window's right edge: when, where, who, and the notes. The notes are
/// HTML and go through the reader's rules: no JavaScript, remote images blocked.
struct EventDetailPanel: View {
    @Bindable var store: CalendarStore

    @State private var note = ""
    @State private var confirmingDelete = false
    @State private var answering: CalendarSOAP.Answer?
    /// "Add a Note..." was picked for this answer: the note field shows with a Send button.
    @State private var noteFor: CalendarSOAP.Answer?
    /// "... and Propose New Time..." was picked: the time fields show, sent as this answer.
    @State private var proposeAs: CalendarSOAP.Answer?
    @State private var proposedStart = Date()
    @State private var proposedEnd = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = store.selectedEvent {
                header(event)
                if confirmingDelete { deleteConfirmation(event) }
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
                if hasPeople(detail) {
                    Divider().opacity(0.6).padding(.horizontal, Self.inset).padding(.top, 14)
                    people(detail)
                }
                if !detail.files.isEmpty, let account = store.account {
                    AttachmentStrip(files: detail.files, accountID: account.id, store: store.mail)
                        .padding(.horizontal, Self.inset)
                        .padding(.top, 12)
                }
                if !detail.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider().opacity(0.6).padding(.top, 14)
                    MessageWebView(html: ReaderHTML.document(body: detail.html, images: [:], allowRemoteImages: false))
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }
            }
        }
        .background(CalendarSurface.background)
        .onChange(of: store.selectedEvent?.id) {
            noteFor = nil
            proposeAs = nil
            note = ""
        }
    }

    /// One inset for every edge and row, so the title, the details, the buttons and the people
    /// all start on the same line.
    static let inset: CGFloat = 16
    /// The icon column every detail and person row shares.
    private static let iconColumn: CGFloat = 16

    /// The title, with round buttons at its top right: Edit and Delete on the user's own events,
    /// then Close, centred on the title's first line.
    private func header(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let charm = event.charm.flatMap(EventCharm.init) {
                    Image(systemName: charm.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(store.tint(for: event))
                        .help(charm.label)
                }
                DirectionalText(event.subject, font: .system(size: 17, weight: .semibold), lines: 3)
                    .strikethrough(event.isCancelled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
            HStack(spacing: 6) {
                // Edit and delete: the user's own appointments and the meetings they organized.
                if store.canEditSelected {
                    roundButton("pencil", help: "Edit") { store.startEditing() }
                        .disabled({ if case .loaded = store.detail { return false } else { return true } }())
                    roundButton("trash", help: "Delete") { confirmingDelete = true }
                }
                roundButton("xmark", help: "Close") { Task { await store.select(nil) } }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// A detail line: its icon in the shared column, then the text.
    private func detailRow<Icon: View, Content: View>(@ViewBuilder icon: () -> Icon,
                                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon().frame(width: Self.iconColumn)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hasPeople(_ detail: EventDetail) -> Bool {
        !detail.event.organizer.isEmpty || !detail.attendees.isEmpty || !detail.rooms.isEmpty
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
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 12)
    }

    // MARK: - Answer (M17)

    /// Accept, Tentative, Decline, as on the invitation email: the click sends the answer, the
    /// chevron offers Send the Response Now, Add a Note..., Don't Send a Response and, on
    /// Tentative and Decline, a proposed new time.
    @ViewBuilder
    private func answerBar(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let answer = proposeAs {
                proposing(answer)
            } else if let answer = noteFor {
                noting(answer)
            } else {
                HStack(spacing: 6) {
                    ForEach(CalendarSOAP.Answer.allCases, id: \.self) { answer in
                        AnswerMenuButton(symbol: answer.symbol, title: answer.label,
                                         help: "\(answer.label) and tell the organizer", compact: true) {
                            send(answer)
                        } menu: {
                            Button("Send the Response Now") { send(answer) }
                            Button("Add a Note...") { noteFor = answer }
                            Button("Don't Send a Response") { send(answer, tell: false) }
                            if answer != .accept {
                                Divider()
                                // Older servers cannot carry a proposed time.
                                Button("\(answer.label) and Propose New Time...") { startProposing(event, as: answer) }
                                    .disabled(!store.canProposeSelected)
                            }
                        }
                    }
                    if answering != nil { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }
                .disabled(answering != nil)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 14)
    }

    private func send(_ answer: CalendarSOAP.Answer, tell: Bool = true, proposal: DateInterval? = nil) {
        answering = answer
        Task {
            await store.answerSelected(answer, note: tell ? note : "", send: tell, proposal: proposal)
            note = ""
            noteFor = nil
            proposeAs = nil
            answering = nil
        }
    }

    private func noting(_ answer: CalendarSOAP.Answer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("A note for the organizer", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...3)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    noteFor = nil
                    note = ""
                }
                sendButton("Send \(answer.label)") { send(answer) }
            }
            .controlSize(.small)
        }
    }

    private func startProposing(_ event: CalendarEvent, as answer: CalendarSOAP.Answer) {
        proposedStart = event.start
        proposedEnd = max(event.end, event.start.addingTimeInterval(15 * 60))
        proposeAs = answer
    }

    /// Tentative or Decline, the new day, start and end, an optional note, and Send.
    private func proposing(_ answer: CalendarSOAP.Answer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(get: { answer }, set: { proposeAs = $0 })) {
                Text("Tentative").tag(CalendarSOAP.Answer.tentative)
                Text("Decline").tag(CalendarSOAP.Answer.decline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            HStack(spacing: 6) {
                FieldBox { PlainDatePicker(date: $proposedStart, elements: .yearMonthDay).fieldInset(-3.5) }
                    .frame(width: 104)
                FieldBox { PlainDatePicker(date: $proposedStart, elements: .hourMinute).fieldInset(-2.5) }
                    .frame(width: 64)
                Text("to").font(.system(size: 12)).foregroundStyle(.secondary)
                FieldBox { PlainDatePicker(date: $proposedEnd, elements: .hourMinute).fieldInset(-2.5) }
                    .frame(width: 64)
                Spacer(minLength: 0)
            }
            // Moving the start keeps the length, as the reader's dashed block does.
            .onChange(of: proposedStart) { old, new in
                proposedEnd = proposedEnd.addingTimeInterval(new.timeIntervalSince(old))
            }
            TextField("A note for the organizer (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    proposeAs = nil
                    note = ""
                }
                sendButton("Send Proposal") {
                    send(answer, proposal: DateInterval(start: proposedStart, end: proposedEnd))
                }
                .disabled(proposedEnd <= proposedStart)
            }
            .controlSize(.small)
        }
    }

    private func sendButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if answering != nil { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(answering != nil)
    }

    private func summary(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if event.isCancelled {
                detailRow { Image(systemName: "xmark.circle") } content: { Text("Cancelled") }
                    .foregroundStyle(.red)
            }
            detailRow {
                Image(systemName: event.isRecurring ? "arrow.2.squarepath" : "clock").foregroundStyle(.secondary)
            } content: {
                Text(timeText(event))
            }
            if !event.location.isEmpty {
                detailRow {
                    Image(systemName: "mappin").foregroundStyle(.secondary)
                } content: {
                    // From the left edge, like every other line, even when Persian.
                    DirectionalText(event.location, font: .system(size: 12), pinnedLeading: true, truncation: .head)
                        .help(event.location)
                }
            }
            if !event.categories.isEmpty {
                detailRow {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(store.categoryColor(event.categories[0]))
                        .frame(width: 10, height: 10)
                } content: {
                    HStack(spacing: 8) {
                        ForEach(Array(event.categories.enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 4) {
                                if index > 0 {
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(store.categoryColor(name))
                                        .frame(width: 10, height: 10)
                                }
                                Text(name)
                            }
                        }
                    }
                }
            }
            if event.isMeeting, !event.isOrganizer, !responseText(event.myResponse).isEmpty {
                detailRow {
                    Image(systemName: responseSymbol(event.myResponse))
                } content: {
                    Text(responseText(event.myResponse))
                }
                .foregroundStyle(event.isTentative ? Color.orange : Color.secondary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary)
        .padding(.horizontal, Self.inset)
    }

    @ViewBuilder
    private func people(_ detail: EventDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(.horizontal, Self.inset)
        .padding(.top, 12)
    }

    private func row(symbol: String, title: String, subtitle: String) -> some View {
        detailRow {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary)
        } content: {
            DirectionalText(title, font: .system(size: 12), pinnedLeading: true)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize()
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
