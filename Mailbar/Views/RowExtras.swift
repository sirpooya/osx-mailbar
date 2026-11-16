import AppKit
import SwiftUI

/// A sender's photo on a row, after Outlook's "Show Sender Image": the people directory's or
/// the server's photo when there is one, else the initials on a colour picked from the name, so
/// one person always gets the same colour. The photo is asked of the store, which holds it only
/// while the popover is open.
struct SenderAvatar: View {
    let name: String
    /// Nil where there is no one address to look up (a Sent row's recipients).
    let address: String?
    let accountID: UUID
    @Bindable var store: MailStore
    var size: CGFloat = 30

    @State private var photo: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Self.color(for: name).opacity(0.22))
            Text(Self.initials(of: name))
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Self.color(for: name))
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: address) {
            photo = nil
            guard let address, !address.isEmpty else { return }
            let found = await store.rowPhoto(for: address, accountID: accountID)
            withAnimation(.easeOut(duration: 0.15)) { photo = found }
        }
    }

    /// "Sara Rahimi" is SR, "Build Server" BS, a lone word its first letter. Brackets, quotes
    /// and an address's domain are skipped; Persian names give their first letters too.
    nonisolated static func initials(of name: String) -> String {
        let cleaned = name.split(separator: "@").first.map(String.init) ?? name
        let words = cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// One of Outlook's persona colours, the same for the same name every time.
    nonisolated static func color(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown, .red, .cyan]
        // A stable hash: Swift's own is seeded per launch.
        let value = name.lowercased().unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(value % UInt32(palette.count))]
    }
}

/// The files under a row, after Outlook's attachment previews: the type's icon and the name,
/// two at most and "+3" for the rest. A click shows the file in Quick Look, fetching it then;
/// right-click saves it. Nothing is fetched to draw the chips.
struct AttachmentChips: View {
    let files: [FileAttachment]
    let accountID: UUID
    @Bindable var store: MailStore

    @State private var busy: String?

    private static let shown = 2

    var body: some View {
        HStack(spacing: 5) {
            ForEach(files.prefix(Self.shown)) { file in
                Button {
                    Task { await open(file, save: false) }
                } label: {
                    HStack(spacing: 4) {
                        if busy == file.id {
                            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                        } else {
                            Image(nsImage: Attachments.icon(for: file.name))
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        Text(Self.shortName(file.name))
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help([file.name, file.sizeLabel].filter { !$0.isEmpty }.joined(separator: ", "))
                .contextMenu {
                    Button("Quick Look") { Task { await open(file, save: false) } }
                    Button("Save…") { Task { await open(file, save: true) } }
                }
            }
            if files.count > Self.shown {
                Text("+\(files.count - Self.shown)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(files.dropFirst(Self.shown).map(\.name).joined(separator: "\n"))
            }
        }
    }

    /// A chip hugs its name, so a long one is cut in the middle here, keeping the extension:
    /// "Spacing tok…v3.pdf". A frame would leave every chip at its widest.
    nonisolated static func shortName(_ name: String, limit: Int = 22) -> String {
        guard name.count > limit else { return name }
        let tail = 8
        return String(name.prefix(limit - tail - 1)) + "…" + String(name.suffix(tail))
    }

    private func open(_ file: FileAttachment, save: Bool) async {
        guard busy == nil, let (url, credential) = store.connection(for: accountID) else { return }
        busy = file.id
        defer { busy = nil }
        do {
            let data = try await store.client.attachmentContent(id: file.id, at: url, credential: credential)
            if save {
                _ = try Attachments.save(data, named: file.name)
            } else {
                try Attachments.preview(data, named: file.name)
            }
        } catch is CancellationError {
            return
        } catch let error as EWSError {
            store.actionError = error.message(host: store.accounts.account(accountID)?.host ?? "The server")
        } catch {
            store.actionError = "Could not \(save ? "save" : "preview") \(file.name): \(error.localizedDescription)"
        }
    }
}

/// An invitation's row adds its time and place and the three answers, after Outlook's "Show
/// Event RSVP". A press tells the organizer at once; a note or a new time needs the message
/// opened, where the full menus are.
struct MeetingRowBar: View {
    let meeting: RowMeeting
    let messageID: String
    let accountID: UUID
    @Bindable var store: MailStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.system(size: 10))
                // The time always shows whole; the place gives way.
                Text(when).font(.system(size: 11)).monospacedDigit()
                    .fixedSize()
                if !meeting.location.isEmpty {
                    Text("·")
                    DirectionalText(meeting.location, font: .system(size: 11), pinnedLeading: true)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let response = meeting.response {
                Label(Self.done(response), systemImage: response == "Decline" ? "xmark.circle" : "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if store.rowAnswering.contains(messageID) {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 5) {
                    ForEach(CalendarSOAP.Answer.allCases, id: \.self) { answer in
                        Button(answer.label) {
                            Task { await store.answerFromRow(answer, message: messageID, in: accountID) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .modifier(TonalCapsule())
                        .help("\(answer.label) and tell the organizer")
                    }
                }
            }
        }
    }

    /// "Sun 23 Nov, 10:00 to 12:00", or "Sun 23 Nov, all day".
    private var when: String {
        let day = meeting.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Self.timeLocale))
        if meeting.isAllDay { return "\(day), all day" }
        let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(Self.timeLocale)
        let sameDay = Calendar.current.isDate(meeting.start, inSameDayAs: meeting.end)
        let end = sameDay ? meeting.end.formatted(time)
            : meeting.end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Self.timeLocale)) + " " + meeting.end.formatted(time)
        return "\(day), \(meeting.start.formatted(time)) to \(end)"
    }

    /// 24-hour times (09:00), as the calendar shows them (en_GB, see `SteppingDatePicker`).
    private static let timeLocale = Locale(identifier: "en_GB")

    private static func done(_ response: String) -> String {
        switch response {
        case "Accept": "Accepted"
        case "Tentative": "Tentatively accepted"
        default: "Declined"
        }
    }
}
