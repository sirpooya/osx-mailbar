import SwiftUI

/// One open message: toolbar, header, body.
///
/// The body and its decoded images live in this view's state and nowhere else. Going back drops
/// them, and so does closing the popover, which goes back first.
struct MessageReaderView: View {
    let accountID: UUID
    /// The row this was opened from, for the header while the body loads and after an action
    /// changes it. Read live from the store so a flag set here shows here.
    let summary: MailMessage
    @Bindable var store: MailStore
    let onBack: () -> Void

    @State private var phase: Phase = .loading
    @State private var allowRemoteImages = QCFlags.loadImages
    /// The meeting a meeting email is for, with its answer; nil for plain mail.
    @State private var meetingCard: MeetingCard?

    private enum Phase: Equatable {
        case loading
        case loaded(MessageBody, images: [String: ImageBytes])
        case failed(String)
    }

    struct ImageBytes: Equatable {
        let type: String
        let data: Data
    }

    static let bodyHeight: CGFloat = 400
    /// The meeting's day above an invitation's description: about five hours of it.
    static let previewHeight: CGFloat = 180

    private var current: MailMessage {
        store.message(summary.id, in: accountID) ?? summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            header
            Divider().opacity(0.5)
            content
                .frame(height: Self.bodyHeight)
        }
        .task(id: summary.id) {
            let card = summary.meeting.map { MeetingCard(kind: $0, mailID: summary.id, accountID: accountID, store: store) }
            meetingCard = card
            async let meeting: Void? = card?.load(senderAddress: summary.senderAddress)
            await load()
            _ = await meeting
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(store.isSearchOpen ? "Results" : store.mailFolder.tabTitle).font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to the Inbox")

            Spacer(minLength: 0)

            responseButtons
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
            MessageActionButtons(message: current, accountID: accountID, store: store,
                                 folder: store.isSearchOpen ? store.searchFolder : store.mailFolder, size: 12)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            DirectionalText(loadedBody?.subject ?? current.subject,
                            font: .system(size: 14, weight: .semibold),
                            highlight: store.highlightTerms)
                .foregroundStyle(.primary)
                .help(loadedBody?.subject ?? current.subject)

            if let card = meetingCard {
                // A meeting email leads with the sender's photo, as Outlook's does, and lists
                // the invited with their answers in place of the To line.
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: fromLine, size: 34, photo: card.organizerPhoto)
                    VStack(alignment: .leading, spacing: 4) {
                        fromAndTime
                        if card.details.map({ !$0.attendees.isEmpty }) == true {
                            MeetingAttendeeLines(card: card)
                        } else {
                            recipients
                        }
                    }
                }
                .padding(.top, 2)
                MeetingInfoLines(card: card, senderName: fromLine, bodyHTML: loadedBody?.html ?? "")
                    .padding(.top, 6)
            } else {
                fromAndTime
                recipients
            }

            if case .loaded(let body, _) = phase, !allowRemoteImages,
               ReaderHTML.hasRemoteImages(body.html) {
                HStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 10))
                    Text("Remote images are blocked.").font(.system(size: 11))
                    Button("Load images") { allowRemoteImages = true }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }

            if let card = meetingCard, card.kind == .request {
                MeetingAnswerBar(card: card)
                    .padding(.top, 8)
            }

            if let files = loadedBody?.files, !files.isEmpty {
                AttachmentStrip(files: files, accountID: accountID, store: store)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Reply, reply all, forward (M12, M13). Available once the message has loaded, since a
    /// reply all needs its recipients.
    private var responseButtons: some View {
        HStack(spacing: 14) {
            responseButton("arrowshape.turn.up.left", help: "Reply  ⌘R", kind: .reply)
                .keyboardShortcut("r", modifiers: .command)
            responseButton("arrowshape.turn.up.left.2", help: "Reply All  ⇧⌘R", kind: .replyAll)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            responseButton("arrowshape.turn.up.right", help: "Forward  ⇧⌘F", kind: .forward)
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    private func responseButton(_ symbol: String, help: String, kind: Draft.Kind) -> some View {
        Button {
            guard let body = loadedBody else { return }
            store.startResponse(kind, to: body, in: accountID)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadedBody == nil)
        .help(help)
        .accessibilityLabel(help)
    }

    private var fromAndTime: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            DirectionalText(fromLine, font: .system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .help(fromAddress)
            Text(current.received.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var recipients: some View {
        if let recipients = recipientLine {
            Text(recipients)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var loadedBody: MessageBody? {
        if case .loaded(let body, _) = phase { return body }
        return nil
    }

    private var fromLine: String {
        loadedBody?.from?.display ?? current.senderName
    }

    private var fromAddress: String {
        loadedBody?.from?.address ?? current.senderAddress
    }

    private var recipientLine: String? {
        guard let body = loadedBody else { return nil }
        var parts: [String] = []
        if !body.to.isEmpty { parts.append("To: " + body.to.map(\.display).joined(separator: ", ")) }
        if !body.cc.isEmpty { parts.append("Cc: " + body.cc.map(\.display).joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening message").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let body, let images):
            let web = MessageWebView(html: ReaderHTML.document(
                body: body.html,
                images: images.mapValues { (type: $0.type, data: $0.data) },
                allowRemoteImages: allowRemoteImages),
                highlight: store.highlightTerms)
            if let card = meetingCard, card.kind == .request, card.phase != .unavailable {
                // The meeting's day above the description; the whole body when there is none.
                VStack(spacing: 0) {
                    if MeetingCard.isBlank(body.html) {
                        MeetingDayPreview(card: card, store: store)
                    } else {
                        MeetingDayPreview(card: card, store: store)
                            .frame(height: Self.previewHeight)
                        Divider().opacity(0.5)
                        web
                    }
                }
            } else {
                web
            }
        case .failed(let message):
            GenericFailureView(message: message) { Task { await load() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading

    private func load() async {
        phase = .loading
        guard let (url, credential) = store.connection(for: accountID) else {
            phase = .failed("The password for this account is missing. Enter it in Settings.")
            return
        }
        do {
            let body = try await store.client.message(id: summary.id, at: url, credential: credential)
            // Inline images are a nicety; the message still opens if they fail.
            let bytes = (try? await store.client.inlineImages(body.inlineImages, at: url, credential: credential)) ?? [:]
            var images: [String: ImageBytes] = [:]
            for image in body.inlineImages {
                if let data = bytes[image.attachmentID] {
                    images[image.contentID] = ImageBytes(type: image.contentType, data: data)
                }
            }
            guard !Task.isCancelled else { return }
            phase = .loaded(body, images: images)
            // Opening a message reads it, as in Outlook. Not tied to this view's task: going back
            // before the server answers cancelled the request and flashed a CancellationError.
            let store = store, id = summary.id, accountID = accountID
            Task { await store.setRead(true, message: id, in: accountID) }
        } catch is CancellationError {
            return
        } catch let error as EWSError {
            phase = .failed(error.message(host: store.accounts.account(accountID)?.host ?? "The server"))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Mark unread or read, flag, archive, delete. The same four in the reader's toolbar and on a
/// hovered row, so they cannot drift apart. Archive leaves out Archive, and Deleted Items leaves
/// out Delete (`MailFolder.canDelete`).
struct MessageActionButtons: View {
    let message: MailMessage
    let accountID: UUID
    @Bindable var store: MailStore
    var folder: MailFolder = .inbox
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: size + 2) {
            button(message.isRead ? "envelope.badge" : "envelope.open",
                   help: message.isRead ? "Mark as unread" : "Mark as read") {
                await store.setRead(!message.isRead, message: message.id, in: accountID)
            }
            button(message.isFlagged ? "flag.slash" : "flag",
                   help: message.isFlagged ? "Clear flag" : "Flag") {
                await store.setFlag(!message.isFlagged, message: message.id, in: accountID)
            }
            if folder.canArchive {
                button("archivebox", help: "Archive") {
                    await store.archive(message: message.id, in: accountID)
                }
            }
            if folder.canDelete {
                button("trash", help: "Delete (moves to Deleted Items)") {
                    await store.delete(message: message.id, in: accountID)
                }
            }
        }
    }

    private func button(_ symbol: String, help: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size + 6, height: size + 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The message's attachments, one chip each: click to open in the default app, right-click to
/// open or save. Bytes are fetched on the click, not with the message (M9).
struct AttachmentStrip: View {
    let files: [FileAttachment]
    let accountID: UUID
    @Bindable var store: MailStore

    @State private var busy: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files) { file in chip(file) }
                }
            }
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ file: FileAttachment) -> some View {
        Button {
            Task { await fetch(file, save: false) }
        } label: {
            HStack(spacing: 5) {
                if busy == file.id {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16)
                } else {
                    Image(nsImage: Attachments.icon(for: file.name))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(file.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)
                if !file.sizeLabel.isEmpty {
                    Text(file.sizeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy != nil)
        .help("Preview \(file.name)")
        .contextMenu {
            Button("Quick Look") { Task { await fetch(file, save: false) } }
            Button("Save As...") { Task { await fetch(file, save: true) } }
        }
    }

    private func fetch(_ file: FileAttachment, save: Bool) async {
        guard let (url, credential) = store.connection(for: accountID) else {
            problem = "The password for this account is missing. Enter it in Settings."
            return
        }
        busy = file.id
        problem = nil
        defer { busy = nil }
        do {
            let data = try await store.client.attachmentContent(id: file.id, at: url, credential: credential)
            if save {
                _ = try Attachments.save(data, named: file.name)
            } else {
                try Attachments.preview(data, named: file.name)
            }
        } catch let error as EWSError {
            problem = error.message(host: store.accounts.account(accountID)?.host ?? "The server")
        } catch {
            problem = "Could not \(save ? "save" : "preview") \(file.name): \(error.localizedDescription)"
        }
    }
}
