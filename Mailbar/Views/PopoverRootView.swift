import AppKit
import SwiftUI

/// The popover: the Inbox and Today tabs, for one account at a time.
///
/// With several accounts a menu at the header's left picks one; there is no swipe between
/// accounts (the user took it out, 2026-09-25). On the Today tab a sideways swipe goes through
/// the days.
struct PopoverRootView: View {
    @Bindable var store: MailStore
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    /// The Today strip's rows open their event in the calendar (M19).
    var onOpenEvent: (UUID, String) -> Void = { _, _ in }

    @Namespace private var tabPill

    private static let width: CGFloat = 380

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Which way the next account change travels, so the inbox leaves the way the swipe went.
    @State private var goesForward = true
    @State private var swipeMonitor: Any?
    @FocusState private var searchFocused: Bool
    @State private var swipe = SwipeTracker()
    @State private var daySwipe = PagerSwipe()

    private static let swipeThreshold: CGFloat = 40
    /// The list's tallest, and the fixed height of both tabs when Today is on.
    static let contentHeight: CGFloat = 460

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
        // Cmd+, opens Settings from anywhere in the popover: the list, a message or the composer.
        .background {
            Button("Settings", action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
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
            if store.isSearchOpen, !showsTodayTab { searchBar }
            Divider().opacity(0.5)
            banners
            ZStack {
                content
                    .id(store.selectedAccount?.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: goesForward ? .trailing : .leading),
                        removal: .move(edge: goesForward ? .leading : .trailing).combined(with: .opacity)))
            }
            // With the Today tab on, both tabs get exactly this height, so switching never resizes
            // the popover: a resize moved the whole panel and read as the header jumping.
            .frame(height: Self.contentHeight, alignment: .top)
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
    /// The Today tab is on (Settings) and chosen.
    private var showsTodayTab: Bool { store.popoverTab == .today }

    private var header: some View {
        ZStack {
            tabSwitch

            // Compose sits at the left edge on both tabs (the user's call, 2026-09-25), then the
            // account menu when there are several accounts.
            HStack(spacing: 10) {
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
                if accounts.count > 1 { accountMenu }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // Search belongs to the Inbox; on the Today tab it leaves the row entirely rather
                // than leaving a hole. It goes and comes without a transition: animated, it slid
                // the icons beside it and the bar looked as if it changed height.
                if !showsTodayTab {
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
                    .transition(.identity)
                }

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Settings (Command ,)")
                .accessibilityLabel("Settings")
            }
            .animation(nil, value: showsTodayTab)
            .foregroundStyle(.secondary)
        }
        // One height whatever the tab shows: the search glyph comes and goes with the Inbox tab,
        // and the bar must not jump when switching (the user's call, 2026-09-25).
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Inbox | Today, in the calendar's capsule style, the unread count on Inbox (M19).
    private var tabSwitch: some View {
        HStack(spacing: 2) {
            tabButton(.inbox, key: "1") {
                HStack(spacing: 4) {
                    Text("Inbox")
                    let count = store.selectedAccount.map { store.unreadCount(for: $0.id) } ?? 0
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            tabButton(.today, key: "2") { Text("Today") }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private func tabButton<Label: View>(_ tab: MailStore.PopoverTab, key: KeyEquivalent,
                                        @ViewBuilder label: () -> Label) -> some View {
        let selected = store.popoverTab == tab
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                store.popoverTab = tab
                if tab == .today { store.closeSearch() }
            }
        } label: {
            label()
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background {
                    if selected {
                        Capsule().fill(CalendarSurface.background)
                            .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "tab", in: tabPill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
    }

    /// With several accounts and the tabs in the middle, the account moves to a menu on the left.
    private var accountMenu: some View {
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
            HStack(spacing: 3) {
                Text(store.selectedAccount?.displayName ?? "").font(.system(size: 11)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: 90, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Content

    /// One case per state and no `default`, so a new state cannot inherit somebody else's view
    /// and no failure can be drawn as an empty inbox.
    @ViewBuilder
    private var content: some View {
        if showsTodayTab, let account = store.selectedAccount {
            TodayDayView(store: store, accountID: account.id,
                         onOpenEvent: { event in onOpenEvent(account.id, event.id) },
                         onOpenCalendar: { onOpenEvent(account.id, "") })
        } else if let account = store.selectedAccount {
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
            // Refresh sits with the time it refreshes, not in the header (the user's call,
            // 2026-09-25). One fixed box for both states, so the spinner cannot shift the line.
            Group {
                if store.isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Check for new mail (Command R)")
                    .accessibilityLabel("Check for new mail")
                }
            }
            .frame(width: 12, height: 12)
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

    /// The account menu: the inbox leaves the way the chosen account lies in the list.
    private func select(_ account: Account) {
        if let from = store.selectedAccount.flatMap({ current in accounts.firstIndex { $0.id == current.id } }),
           let to = accounts.firstIndex(where: { $0.id == account.id }) {
            goesForward = to > from
        }
        store.selectedAccountID = account.id
    }

    /// A trackpad swipe is a run of scroll events with phases, which no SwiftUI gesture reports,
    /// so a local monitor collects them. It never consumes the event: the list still scrolls.
    private func installSwipe() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Local monitors run on the main thread; the event just is not marked Sendable.
            nonisolated(unsafe) let scroll = event
            let consumed = MainActor.assumeIsolated { handleSwipe(scroll) }
            return consumed ? nil : event
        }
    }

    private func removeSwipe() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }

    /// True when the swipe paged the Today tab's day and must not also scroll the hours.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        // On the Today tab: through the days, only for swipes inside the popover itself.
        if store.openMessage == nil, !store.isComposing, showsTodayTab,
           let window = store.popoverWindow, event.window === window {
            return daySwipe.handle(event, pager: store.dayPager)
        }
        // In a message: back, fingers moving right, as in Safari.
        if store.openMessage != nil {
            if event.phase.contains(.began) {
                swipe.began()
            } else if event.phase.contains(.changed) {
                swipe.moved(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                if swipe.ended(threshold: Self.swipeThreshold) == .right { back() }
            }
        }
        return false
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
                            // The same inset on both sides as the row's own content, no special
                            // left indent (the user's call, 2026-09-25).
                            .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
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
        .frame(maxHeight: PopoverRootView.contentHeight)
    }
}
