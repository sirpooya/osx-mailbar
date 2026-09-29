import AppKit
import SwiftUI

/// The meeting a meeting email is for, under the reader's From line: when and where with a Join
/// button, who is invited and how each answered, and for a cancellation or an answer what it
/// says. After Outlook's invitation header.
struct MeetingInfoLines: View {
    @Bindable var card: MeetingCard
    let senderName: String
    let bodyHTML: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch card.kind {
            case .response(let response): responseLine(response)
            case .cancellation: cancellationLine
            case .request: EmptyView()
            }
            if let details = card.details {
                whenLine(details)
                if !details.event.location.isEmpty || card.joinLink(bodyHTML: bodyHTML) != nil {
                    whereLine(details)
                }
            }
        }
    }

    private func whenLine(_ details: MeetingDetails) -> some View {
        HStack(spacing: 6) {
            Image(systemName: details.event.isRecurring ? "arrow.2.squarepath" : "calendar")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(MeetingText.when(details.event))
                .font(.system(size: 12, weight: .semibold))
                .strikethrough(card.kind == .cancellation)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help(details.event.isRecurring ? "A repeating meeting" : "")
    }

    private func whereLine(_ details: MeetingDetails) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            DirectionalText(details.event.location.isEmpty ? "Online" : details.event.location,
                            font: .system(size: 12), pinnedLeading: true, truncation: .head)
                .foregroundStyle(.secondary)
                .help(details.event.location)
            if let link = card.joinLink(bodyHTML: bodyHTML), card.kind != .cancellation {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(link.host ?? "Join the meeting")
            }
        }
    }

    /// "Sara Rahimi tentatively accepted.", and the time they proposed, if they did.
    private func responseLine(_ response: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: MeetingText.mark(response ?? ""))
                    .foregroundStyle(MeetingText.color(response ?? ""))
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text("\(senderName) \(MeetingText.verb(response)).")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let proposal = card.details?.proposal {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 14)
                    Text("Proposed: \(MeetingText.when(start: proposal.start, end: proposal.end, allDay: false))")
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Says so, and offers Remove from Calendar while the event is still there.
    private var cancellationLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.minus")
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text(cancellationText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if card.details?.calendarItemID != nil, !card.removedFromCalendar {
                    Button {
                        Task { await card.removeFromCalendar() }
                    } label: {
                        HStack(spacing: 4) {
                            if card.removing { ProgressView().controlSize(.mini) }
                            Text("Remove from Calendar").font(.system(size: 12))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .modifier(TonalCapsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(card.removing)
                }
            }
            if let problem = card.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private var cancellationText: String {
        if card.removedFromCalendar { return "Cancelled, and removed from your calendar." }
        if case .loaded(let details) = card.phase, details.calendarItemID == nil {
            return "Cancelled. It is not on your calendar."
        }
        return "This meeting was cancelled."
    }
}

/// "Required: ✓ Sara Rahimi, ◷ Omid Karimi", each name with the answer the server holds for
/// them, after Outlook's attendee line. Wraps onto a second line, then truncates.
struct MeetingAttendeeLines: View {
    @Bindable var card: MeetingCard

    var body: some View {
        let required = card.attendees(optional: false)
        let optional = card.attendees(optional: true)
        VStack(alignment: .leading, spacing: 2) {
            if !required.isEmpty { line(optional.isEmpty && required.count < 2 ? "Invited" : "Required", required) }
            if !optional.isEmpty { line("Optional", optional) }
        }
    }

    private func line(_ label: String, _ people: [EventDetail.Attendee]) -> some View {
        people.enumerated().reduce(Text("\(label): ").foregroundStyle(.secondary)) { text, pair in
            let (index, person) = pair
            return text
                + Text(index == 0 ? "" : ",  ")
                + Text(Image(systemName: "circle.fill")).font(.system(size: 7)).baselineOffset(1)
                    .foregroundStyle(MeetingText.color(card.status(of: person)))
                + Text(" \(person.display)")
        }
        .font(.system(size: 11))
        .lineLimit(2)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(people.map { "\($0.display): \(card.status(of: $0).label)" }.joined(separator: "\n"))
    }
}

/// Accept, Tentative, Decline and Propose on an invitation (M17), each with Outlook's choices
/// behind a chevron: send now, add a note, or send nothing. Once answered it says so, with
/// Change to answer again.
struct MeetingAnswerBar: View {
    @Bindable var card: MeetingCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.phase == .loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading the meeting").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(height: 24)
            } else if card.isOrganizer {
                statusLine(symbol: "person.crop.circle.badge.checkmark", color: .secondary,
                           text: "You organized this meeting.", change: false)
            } else if card.proposal != nil {
                proposing
            } else if let answer = card.noteFor {
                noting(answer)
            } else if !card.showsAnswerButtons, let answer = card.myAnswer {
                statusLine(symbol: MeetingText.mark(answer.responseType), color: MeetingText.color(answer.responseType),
                           text: answeredText(answer), change: true)
            } else {
                buttons
            }
            if let problem = card.problem, card.kind == .request {
                Text(problem).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func answeredText(_ answer: CalendarSOAP.Answer) -> String {
        var text = "You \(answer.pastTense)."
        if let proposed = card.proposed {
            text += " Proposed \(MeetingText.when(start: proposed.start, end: proposed.end, allDay: false, short: true))."
        }
        if card.answeredSilently { text += " The organizer was not told." }
        return text
    }

    private func statusLine(symbol: String, color: Color, text: String, change: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 12))
            Text(text).font(.system(size: 12)).lineLimit(2)
            if change {
                Button("Change") { card.changing = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 24)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ForEach(CalendarSOAP.Answer.allCases, id: \.self) { answer in
                AnswerMenuButton(symbol: answer.symbol, title: answer.label,
                                 help: "\(answer.label) and tell the organizer") {
                    Task { await card.answer(answer) }
                } menu: {
                    Button("Send the Response Now") { Task { await card.answer(answer) } }
                    Button("Add a Note...") { card.noteFor = answer }
                    Button("Don't Send a Response") { Task { await card.answer(answer, send: false) } }
                    if answer != .accept {
                        Divider()
                        // Older servers cannot carry a proposed time.
                        Button("\(answer.label) and Propose New Time...") { card.startProposing(as: answer) }
                            .disabled(!card.canPropose || card.details == nil)
                    }
                }
                .disabled(card.sending != nil)
            }
            if card.sending != nil { ProgressView().controlSize(.small) }
            if card.changing {
                Button {
                    card.changing = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Keep the answer")
            }
            Spacer(minLength: 0)
        }
    }

    private func noting(_ answer: CalendarSOAP.Answer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("A note for the organizer", text: $card.note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...3)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    card.noteFor = nil
                    card.note = ""
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task { await card.answer(answer) }
                } label: {
                    HStack(spacing: 4) {
                        if card.sending == answer { ProgressView().controlSize(.mini) }
                        Text("Send \(answer.label)")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(card.sending != nil)
            }
            .controlSize(.small)
        }
    }

    /// Tentative or Decline, the time picked in the day below, an optional note, and Send.
    private var proposing: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $card.proposeAs) {
                    Text("Tentative").tag(CalendarSOAP.Answer.tentative)
                    Text("Decline").tag(CalendarSOAP.Answer.decline)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Text("Drag the dashed block to a new time.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            TextField("A note for the organizer (optional)", text: $card.note)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { card.cancelProposing() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await card.sendProposal() }
                } label: {
                    HStack(spacing: 4) {
                        if card.sending != nil { ProgressView().controlSize(.mini) }
                        Text("Send Proposal")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(card.sending != nil)
            }
            .controlSize(.small)
        }
    }
}

/// A rounded split button in the accent's tone (the user's call, 2026-09-27): the click
/// answers, the chevron after a thin divider offers the choices.
struct AnswerMenuButton<MenuItems: View>: View {
    let symbol: String
    let title: String
    let help: String
    /// No glyph and tighter padding, so three fit the calendar's 330 pt detail panel.
    var compact = false
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuItems

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 5) {
                    if !compact { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                    Text(title).font(.system(size: 12, weight: .medium))
                }
                .padding(.leading, compact ? 10 : 12)
                .padding(.trailing, compact ? 6 : 7)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 1, height: 14)
            Menu(content: menu) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, compact ? 6 : 7)
            .padding(.trailing, compact ? 8 : 10)
            .frame(height: 26)
            .help("More choices")
        }
        .tint(.accentColor)
        .modifier(TonalCapsule())
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A capsule in the accent's tone: accent text on a light accent fill.
struct TonalCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.accentColor)
            .background(Capsule().fill(Color.accentColor.opacity(0.13)))
            .contentShape(Capsule())
    }
}

/// The day the meeting falls on, after Outlook's invitation view: that day's events around it,
/// the invitation hatched until answered, so a clash shows at a glance. While a new time is
/// being proposed a dashed block marks it; drag it, or click a time, and the arrows go to
/// another day.
struct MeetingDayPreview: View {
    @Bindable var card: MeetingCard
    @Bindable var store: MailStore

    private let hourHeight: CGFloat = 30
    private static let gutter: CGFloat = 42
    private static let space = "meetingDay"

    @State private var dragStart: Date?

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        let (others, meeting) = card.previewEvents()
        VStack(spacing: 0) {
            header
            let allDay = (others + [meeting].compactMap { $0 }).filter(\.isAllDay)
            if !allDay.isEmpty {
                HStack(spacing: 4) {
                    Text("all day").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .frame(width: Self.gutter - 6, alignment: .trailing)
                    ForEach(allDay) { event in
                        EventBlock(event: event, isSelected: event.id == meeting?.id, compact: true,
                                   tint: store.tint(for: event, in: card.accountID))
                            .frame(height: 18)
                    }
                }
                .padding(.trailing, 8)
                .padding(.bottom, 3)
            }
            grid(others: others.filter { !$0.isAllDay }, meeting: meeting?.isAllDay == true ? nil : meeting)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if card.proposal != nil { dayArrow(-1) }
            Text(card.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 12, weight: .semibold))
            if card.proposal != nil { dayArrow(1) }
            if card.dayEvents == nil {
                if card.dayFailed {
                    Label("Could not load the day", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            Spacer(minLength: 0)
            if let proposal = card.proposal {
                Text(MeetingText.timeRange(proposal.start, proposal.end))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
            } else if card.myAnswer == nil, !card.isOrganizer, card.details != nil {
                Text("Please respond")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: 28)
    }

    private func dayArrow(_ offset: Int) -> some View {
        Button {
            Task { await card.showDay(offset: offset) }
        } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .foregroundStyle(Color.accentColor)
                .background(Circle().fill(Color.accentColor.opacity(0.13)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(offset < 0 ? "The day before" : "The day after")
    }

    private func grid(others: [CalendarEvent], meeting: CalendarEvent?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(CalendarWeekView.hourLabel(hour))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: Self.gutter - 8, height: hourHeight, alignment: .topLeading)
                                .padding(.leading, 8)
                                .offset(y: -6)
                                .id("meeting-hour-\(hour)")
                        }
                    }
                    column(others: others, meeting: meeting)
                        .frame(height: hourHeight * 24)
                }
                .padding(.top, 6)
                .padding(.trailing, 8)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: card.day) { scroll(proxy) }
            .onChange(of: card.details?.event.start) { scroll(proxy) }
        }
    }

    /// The hour before the meeting (or the proposed time) at the top.
    private func scroll(_ proxy: ScrollViewProxy) {
        let anchor = card.proposal?.start ?? card.details?.event.start
        let hour = anchor.map { calendar.isDate($0, inSameDayAs: card.day) ? calendar.component(.hour, from: $0) : 8 } ?? 8
        DispatchQueue.main.async { proxy.scrollTo("meeting-hour-\(max(hour - 1, 0))", anchor: .top) }
    }

    private func column(others: [CalendarEvent], meeting: CalendarEvent?) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                HourBackground(isWorkDay: Keys.calendarWorkDays().contains(calendar.component(.weekday, from: card.day)),
                               workHours: Keys.calendarWorkHours(), hourHeight: hourHeight)
                ForEach(EventLayout.place(others + [meeting].compactMap { $0 }, on: card.day, calendar: calendar)) { placed in
                    let x = CGFloat(placed.column) / CGFloat(placed.columns) * (width - 6) + 3
                    let w = (width - 6) / CGFloat(placed.columns) - 2
                    let h = max((placed.endHour - placed.startHour) * hourHeight - 2, 16)
                    EventBlock(event: placed.event, isSelected: placed.event.id == meeting?.id, compact: h < 30,
                               tint: store.tint(for: placed.event, in: card.accountID), height: h, width: max(w, 10))
                        .frame(width: max(w, 10), height: h)
                        .opacity(card.proposal != nil && placed.event.id == meeting?.id ? 0.55 : 1)
                        .offset(x: x, y: placed.startHour * hourHeight)
                        .allowsHitTesting(false)
                }
                if calendar.isDateInToday(card.day) {
                    NowLine(calendar: calendar, hourHeight: hourHeight, width: width - 4)
                        .padding(.leading, 4)
                }
                if let proposal = card.proposal { proposalBand(proposal, width: width) }
            }
            .coordinateSpace(name: Self.space)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .named(Self.space)) { location in
                guard let proposal = card.proposal else { return }
                // The click lands in the middle of the proposed time.
                let start = card.day.addingTimeInterval(Double(location.y / hourHeight) * 3600 - proposal.duration / 2)
                card.moveProposal(to: start)
            }
        }
    }

    private func hours(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(card.day) / 3600)
    }

    /// The proposed time: dashed, in the accent, dragged with the hand in 15-minute steps. The
    /// drag is measured in the column's space, never the band's, which moves under the hand.
    private func proposalBand(_ proposal: DateInterval, width: CGFloat) -> some View {
        let height = max(CGFloat(proposal.duration / 3600) * hourHeight - 2, 14)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.accentColor.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .overlay(alignment: .topLeading) {
                Text("Proposed  \(MeetingText.timeRange(proposal.start, proposal.end))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
            }
            .frame(width: width - 8, height: height)
            .offset(x: 4, y: hours(proposal.start) * hourHeight)
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = proposal.start
                        NSCursor.closedHand.push()
                    }
                    guard let dragStart else { return }
                    card.moveProposal(to: dragStart.addingTimeInterval(Double(value.translation.height / hourHeight) * 3600))
                }
                .onEnded { _ in
                    if dragStart != nil { NSCursor.pop() }
                    dragStart = nil
                })
            .help("Drag to move the proposed time")
    }
}

/// The words the meeting views share.
enum MeetingText {
    /// "Sunday 27 September, 15:00 to 15:30" in the Mac's own date and time style.
    static func when(_ event: CalendarEvent) -> String {
        when(start: event.start, end: event.end, allDay: event.isAllDay)
    }

    static func when(start: Date, end: Date, allDay: Bool, short: Bool = false) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: Date())
        var style = Date.FormatStyle.dateTime.day().month(short ? .abbreviated : .wide)
        style = style.weekday(short ? .abbreviated : .wide)
        if !sameYear { style = style.year() }
        let day = start.formatted(style)
        if allDay {
            let last = end.addingTimeInterval(-1)
            return calendar.isDate(start, inSameDayAs: last) ? "\(day), all day" : "\(day) to \(last.formatted(style))"
        }
        if calendar.isDate(start, inSameDayAs: end) || end == calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) {
            return "\(day), \(timeRange(start, end))"
        }
        return "\(day) \(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(style)) \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func mark(_ response: String) -> String {
        switch response {
        case "Accept": return "checkmark.circle.fill"
        case "Tentative": return "questionmark.circle.fill"
        case "Decline": return "xmark.circle.fill"
        case "Organizer": return "person.crop.circle.fill"
        default: return "clock"
        }
    }

    static func color(_ response: String) -> Color {
        switch response {
        case "Accept": return .green
        case "Tentative": return .orange
        case "Decline": return .red
        default: return .secondary
        }
    }

    /// Green free or accepted, amber tentative, red busy or declined, purple away, grey unknown.
    static func color(_ status: MeetingStatus) -> Color {
        switch status {
        case .accepted, .free: return .green
        case .tentative, .tentativeTime: return .orange
        case .declined, .busy: return .red
        case .away: return .purple
        case .elsewhere: return .teal
        case .noAnswer, .noInformation: return Color.secondary.opacity(0.6)
        }
    }

    static func answerName(_ response: String) -> String {
        switch response {
        case "Accept": return "Accepted"
        case "Tentative": return "Tentative"
        case "Decline": return "Declined"
        case "Organizer": return "Organizer"
        default: return "No answer yet"
        }
    }

    /// "accepted", for an answer email's line.
    static func verb(_ response: String?) -> String {
        switch response {
        case "Accept": return "accepted"
        case "Tentative": return "tentatively accepted"
        case "Decline": return "declined"
        default: return "answered"
        }
    }
}
