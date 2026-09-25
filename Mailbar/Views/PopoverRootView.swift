import AppKit
import SwiftUI

/// The popover: one view, the Inbox, for one account at a time.
///
/// With several accounts the title becomes a menu, and a two-finger swipe steps between them the
/// way osx-jirabar steps between board columns. With one account there is nothing to switch and
/// the title is plain text.
struct PopoverRootView: View {
    @Bindable var store: MailStore
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    /// The Today strip's rows open their event in the calendar (M19).
    var onOpenEvent: (UUID, String) -> Void = { _, _ in }

    @AppStorage(Keys.showToday) private var showToday = true

    private static let width: CGFloat = 380

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the next account change travels, so the inbox leaves the way the swipe went.
    @State private var goesForward = true
    @State private var swipeMonitor: Any?
    @FocusState private var searchFocused: Bool
    @State private var swipe = SwipeTracker()

    private static let swipeThreshold: CGFloat = 40

    private var accounts: [Account] { store.accounts.accounts }

    var body: some View {
        VStack(spacing: 0) {
            if MockMode.current != nil { sampleDataBanner }
            if store.isComposing, store.draft != nil {
                ComposeView(store: store, onClose: { store.isComposing = false })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let open = store.openMessage,
               let message = store.message(open.messageID, in: open.accountID) {
                banners
                MessageReaderView(accountID: open.accountID, summary: message, store: store,
                                  onBack: back)
                    // Pushed in from the trailing edge, the list leaving to the leading one, as
                    // in osx-jirabar. Going back runs it the other way.
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .snappy(duration: store.openMessage == nil ? 0.3 : 0.22),
                   value: store.openMessage)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.isComposing)
        .frame(width: Self.width)
        // An opaque surface, not the popover's glass. On macOS 26 the popover glass adapts to the
        // LUMINANCE of whatever is behind it, independent of the light or dark appearance, so over
        // a dark wallpaper in Light mode it went dark while the text stayed light-mode dark:
        // primary text read dim grey and secondary read brighter than it (measured 2026-09-24).
        // The window background follows the appearance itself, so the text always matches it.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { installSwipe() }
        .onDisappear { removeSwipe() }
    }

    private func back() {
        store.openMessage = nil
    }

    /// The list screen: header, banners, the selected account's inbox, footer.
    private var list: some View {
        VStack(spacing: 0) {
            header
            if store.isSearchOpen { searchBar }
            if showToday, !store.isSearchOpen, let account = store.selectedAccount,
               !store.todayEvents(for: account.id).isEmpty {
                TodayStrip(events: store.todayEvents(for: account.id), joinLinks: store.joinLinks) { event in
                    onOpenEvent(account.id, event.id)
                }
            }
            Divider().opacity(0.5)
            banners
            ZStack {
                content
                    .id(store.selectedAccount?.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: goesForward ? .trailing : .leading),
                        removal: .move(edge: goesForward ? .leading : .trailing).combined(with: .opacity)))
            }
            .clipped()
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: store.selectedAccount?.id)
            Divider().opacity(0.5)
            footer
        }
    }

    // MARK: - Banners

    /// A failed action, and the one question the app ever asks about the mailbox: whether to
    /// create an Archive folder. Inline rather than an alert, which an `NSPopover` presents badly.
    @ViewBuilder
    private var banners: some View {
        if let pending = store.pendingArchive {
            banner(symbol: "archivebox", tint: .accentColor,
                   text: "\(store.accounts.account(pending.accountID)?.displayName ?? "This mailbox") has no Archive folder yet.") {
                Button("Create and Archive") { Task { await store.createArchiveFolderAndArchive() } }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { store.pendingArchive = nil }
            }
        }
        if let notice = store.sentNotice {
            banner(symbol: "paperplane.fill", tint: .green, text: notice) { EmptyView() }
        }
        if let draft = store.draft, !store.isComposing, draft.hasContent {
            banner(symbol: "square.and.pencil", tint: .accentColor,
                   text: "\(draft.title) not sent yet.") {
                Button("Continue") { store.isComposing = true }
            }
        }
        if let error = store.actionError {
            banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error) {
                Button("Dismiss") { store.actionError = nil }
            }
        }
    }

    private func banner<Actions: View>(symbol: String, tint: Color, text: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack(spacing: 6) { actions() }.controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.10))
    }

    /// Loud on purpose: fixture mail looks exactly like real mail.
    private var sampleDataBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("SAMPLE DATA").font(.system(size: 10, weight: .bold))
            Text("not your mailbox. Launched with MAILBAR_MOCK.").font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.yellow)
    }

    // MARK: - Header

    /// A ZStack so the title stays centred on the panel whatever the buttons beside it measure.
    private var header: some View {
        ZStack {
            title

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button {
                    store.startNewMessage()
                } label: {
                    Image(systemName: store.draft?.kind == .new && store.draft?.hasContent == true
                          ? "square.and.pencil.circle" : "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .help(store.draft?.hasContent == true ? "Back to the message you are writing" : "New message (Command N)")
                .accessibilityLabel("New message")
                .disabled(store.selectedAccount == nil)

                Button {
                    if store.isSearchOpen { store.closeSearch() } else { store.isSearchOpen = true }
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .help("Search the Inbox (Cmd+F)")
                .accessibilityLabel("Search the Inbox")
                .disabled(store.selectedAccount == nil)

                // One fixed box for both states, so the spinner replacing the button cannot nudge
                // the header's height (osx-jirabar measured that one).
                Group {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .help("Check for new mail")
                        .accessibilityLabel("Check for new mail")
                    }
                }
                .frame(width: 16, height: 14)

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var title: some View {
        if accounts.count > 1 {
            Menu {
                ForEach(accounts) { account in
                    Button {
                        select(account)
                    } label: {
                        let count = store.unreadCount(for: account.id)
                        Label(count > 0 ? "\(account.displayName)  (\(count))" : account.displayName,
                              systemImage: store.selectedAccount?.id == account.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    titleText
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            // `.button` renders the whole composed label; `.borderlessButton` drops all but the
            // first view (osx-jirabar).
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Inbox of \(store.selectedAccount?.displayName ?? "no account"). Choose an account.")
        } else {
            titleText
        }
    }

    private var titleText: some View {
        HStack(spacing: 5) {
            Text(accounts.count > 1 ? "Inbox · \(store.selectedAccount?.displayName ?? "")" : "Inbox")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            let count = store.selectedAccount.map { store.unreadCount(for: $0.id) } ?? 0
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 12)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help(count == 1 ? "1 unread message" : "\(count) unread messages")
            }
        }
    }

    // MARK: - Content

    /// One case per state and no `default`, so a new state cannot inherit somebody else's view
    /// and no failure can be drawn as an empty inbox.
    @ViewBuilder
    private var content: some View {
        if let account = store.selectedAccount {
            if store.isSearchOpen, store.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                searchContent(account)
            } else {
                inboxContent(account)
            }
        } else {
            NoAccountsView(onOpenSettings: onOpenSettings)
        }
    }

    // MARK: - Search

    /// The field under the header. Typing searches the server after a short pause, so each
    /// keystroke does not become a request; results that arrive after the text changed are dropped
    /// by the store.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search Inbox", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { Task { await store.runSearch() } }
            if !store.searchQuery.isEmpty {
                Button {
                    store.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear")
            }
            Button("Done") { store.closeSearch() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .onAppear { searchFocused = true }
        .task(id: store.searchQuery) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await store.runSearch()
        }
    }

    @ViewBuilder
    private func searchContent(_ account: Account) -> some View {
        switch store.searchPhase {
        case .idle, .searching:
            SkeletonListView(rowCount: 3)
        case .results(let messages) where messages.isEmpty:
            StatePlaceholder(symbol: "magnifyingglass", tint: .secondary,
                             title: "No messages match",
                             message: "Nothing in the Inbox of \(account.displayName) matches \u{201C}\(store.searchQuery)\u{201D}.") {
                EmptyView()
            }
        case .results(let messages):
            InboxListView(messages: messages, accountID: account.id, store: store)
        case .failed(let message):
            GenericFailureView(message: message) { Task { await store.runSearch() } }
        }
    }

    @ViewBuilder
    private func inboxContent(_ account: Account) -> some View {
        do {
            switch store.state(for: account.id) {
            case .loading:
                SkeletonListView()
            case .messages(let messages):
                InboxListView(messages: messages, accountID: account.id, store: store)
            case .empty:
                EmptyInboxView(onRefresh: onRefresh)
            case .needsPassword:
                NeedsPasswordView(onOpenSettings: onOpenSettings)
            case .passwordRejected:
                PasswordRejectedView(host: account.host, onOpenSettings: onOpenSettings)
            case .unreachable(let reason):
                UnreachableView(host: account.host, reason: reason, onRetry: onRefresh)
            case .failed(let message):
                GenericFailureView(message: message, onRetry: onRefresh)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let account = store.selectedAccount, !account.email.isEmpty {
                Text(account.email).lineLimit(1).truncationMode(.middle)
                Text("·")
            }
            if let last = store.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Not updated yet")
            }
            Spacer(minLength: 4)
            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Switching accounts

    /// Used by the menu and the swipe alike, so choosing from the menu travels the same way as
    /// swiping to the same account.
    private func select(_ account: Account) {
        if let from = store.selectedAccount.flatMap({ current in accounts.firstIndex { $0.id == current.id } }),
           let to = accounts.firstIndex(where: { $0.id == account.id }) {
            goesForward = to > from
        }
        store.selectedAccountID = account.id
    }

    private func step(forward: Bool) {
        guard let current = store.selectedAccount,
              let index = accounts.firstIndex(where: { $0.id == current.id }) else { return }
        let next = index + (forward ? 1 : -1)
        // The ends hold instead of wrapping.
        guard accounts.indices.contains(next) else { return }
        select(accounts[next])
    }

    /// A trackpad swipe is a run of scroll events with phases, which no SwiftUI gesture reports,
    /// so a local monitor collects them. It never consumes the event: the list still scrolls.
    private func installSwipe() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleSwipe(event)
            return event
        }
    }

    private func removeSwipe() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    private func handleSwipe(_ event: NSEvent) {
        // Inside a message the only swipe is back, fingers moving right, as in Safari.
        if store.openMessage != nil {
            if event.phase.contains(.began) {
                swipe.began()
            } else if event.phase.contains(.changed) {
                swipe.moved(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                if swipe.ended(threshold: Self.swipeThreshold) == .right { back() }
            }
            return
        }
        guard accounts.count > 1 else { return }
        if event.phase.contains(.began) {
            swipe.began()
        } else if event.phase.contains(.changed) {
            swipe.moved(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            // Fingers moving left bring in the next account, as with pages.
            if let direction = swipe.ended(threshold: Self.swipeThreshold) {
                step(forward: direction == .left)
            }
        }
    }
}

struct InboxListView: View {
    let messages: [MailMessage]
    let accountID: UUID
    @Bindable var store: MailStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 24)
                            .padding(.trailing, 10)
                    }
                    MessageRowView(message: message, accountID: accountID, store: store,
                                   startsHovered: index == 0 && QCFlags.hoverFirstRow) {
                        store.actionError = nil
                        store.openMessage = .init(accountID: accountID, messageID: message.id)
                    }
                    // A row that leaves (archived, deleted) fades and gives up its height, so the
                    // rows below are seen to close the gap rather than teleporting up.
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            // Keyed on WHICH messages are present, not their values: a poll that returns the same
            // rows must not make the list twitch.
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: messages.map(\.id))
        }
        // About seven rows in the popover, which must not run past the bottom of the screen.
        .frame(maxHeight: 460)
    }
}

/// The rest of today, above the inbox (M19): the time, the title, how soon the next one starts,
/// and a Join button when its notes carry a meeting link. Up to three rows; a row opens the event
/// in the calendar.
struct TodayStrip: View {
    let events: [CalendarEvent]
    let joinLinks: [String: URL]
    let onOpen: (CalendarEvent) -> Void

    private static let shown = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let upcoming = events.filter { $0.end > now }
            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    // "Next" is the first one that has not started: it gets the "in 25 min". One
                    // under way already says "Now" instead.
                    let next = upcoming.firstIndex { !$0.isAllDay && $0.start > now }
                    ForEach(Array(upcoming.prefix(Self.shown).enumerated()), id: \.element.id) { index, event in
                        row(event, isNext: index == next, now: now)
                    }
                    if upcoming.count > Self.shown {
                        Text("+\(upcoming.count - Self.shown) more today")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 14)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                .padding(.horizontal, 10)
                .padding(.bottom, 7)
            }
        }
    }

    private func row(_ event: CalendarEvent, isNext: Bool, now: Date) -> some View {
        let underway = !event.isAllDay && event.start <= now
        return Button { onOpen(event) } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(event.isTentative ? 0.45 : 1))
                    .frame(width: 3, height: 14)
                Text(event.isAllDay ? "All day" : (underway ? "Now" : event.start.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 11, weight: underway ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(underway ? Color.accentColor : Color.secondary)
                    .frame(width: 58, alignment: .leading)
                DirectionalText(event.subject, font: .system(size: 12, weight: isNext || underway ? .semibold : .regular))
                if isNext, !underway {
                    Text(TodayAgenda.relative(event, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let link = joinLinks[event.id] {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Label("Join", systemImage: "video.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help(link.host ?? "Join the meeting")
                    .fixedSize()
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([event.subject, event.location].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
