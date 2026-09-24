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
        .task(id: summary.id) { await load() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Inbox").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to the Inbox")

            Spacer(minLength: 0)

            MessageActionButtons(message: current, accountID: accountID, store: store, size: 12)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            DirectionalText(loadedBody?.subject ?? current.subject,
                            font: .system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .help(loadedBody?.subject ?? current.subject)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                DirectionalText(fromLine, font: .system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .help(fromAddress)
                Text(current.received.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if let recipients = recipientLine {
                Text(recipients)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            MessageWebView(html: ReaderHTML.document(
                body: body.html,
                images: images.mapValues { (type: $0.type, data: $0.data) },
                allowRemoteImages: allowRemoteImages))
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
            // Opening a message reads it, as in Outlook.
            await store.setRead(true, message: summary.id, in: accountID)
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
/// hovered row, so they cannot drift apart.
struct MessageActionButtons: View {
    let message: MailMessage
    let accountID: UUID
    @Bindable var store: MailStore
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
            button("archivebox", help: "Archive") {
                await store.archive(message: message.id, in: accountID)
            }
            button("trash", help: "Delete (moves to Deleted Items)") {
                await store.delete(message: message.id, in: accountID)
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
