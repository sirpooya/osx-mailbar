import AppKit
import SwiftUI

/// The popover: the mail and Today tabs, for one account at a time.
///
/// A menu at the header's left picks the folder, Inbox or Sent Items, and with several accounts
/// the account too; there is no swipe between
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
    @State private var showsUpdating = false
    @State private var updatingSince: Date?
    @FocusState private var searchFocused: Bool
    @State private var swipe = SwipeTracker()
    @State private var daySwipe = PagerSwipe()
    /// A two-finger swipe across a row (M20), and whether it has locked sideways or vertical.
    @State private var rowSwipe = SwipeTracker()
    @State private var rowSwipeSideways: Bool?

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
        .onAppear { installSwipe() }
        .onDisappear { removeSwipe() }
        // Whether the opened message has a List-Unsubscribe header, for the reader's button (M20).
        .task(id: store.openMessage) {
            guard let open = store.openMessage else { return }
            _ = await store.unsubscribeLink(for: open.messageID, in: open.accountID)
        }
        // A search stays open across folders and looks again in the one now showing.
        .onChange(of: store.mailFolder) { _, _ in
            if store.isSearchOpen { Task { await store.runSearch() } }
        }
    }

    private func back() {
        store.openMessage = nil
    }

    /// The list screen: header, banners, the selected account's inbox, footer.
    private var list: some View {
        VStack(spacing: 0) {
            header
            if store.isSearchOpen, !showsTodayTab { searchBar }
            if !showsTodayTab, !store.listOptions.filters(in: store.mailFolder).isEmpty { filterStrip }
            if !showsTodayTab, !store.isSearchOpen, let account = store.selectedAccount,
               MailStore.emptyTarget(store.mailFolder) != nil,
               !(store.list(store.mailFolder, for: account.id)?.messages.isEmpty ?? true) {
                emptyStrip(account)
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
            // With the Today tab on, both tabs get exactly this height, so switching never resizes
            // the popover: a resize moved the whole panel and read as the header jumping.
            .frame(height: Self.contentHeight, alignment: .top)
            .clipped()
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: store.selectedAccount?.id)
            // The undo toast floats over the list's foot for its five seconds (M20).
            .overlay(alignment: .bottom) {
                if let toast = store.listActions.toast, !showsTodayTab {
                    UndoToastView(toast: toast, store: store)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.listActions.toast)
            Divider().opacity(0.5)
            // Two or more rows selected: their actions take the footer's place.
            if let account = store.selectedAccount, !showsTodayTab, store.listActions.selection.count >= 2 {
                SelectionBar(ids: Array(store.listActions.selection), accountID: account.id,
                             folder: listFolder, store: store)
            } else {
                footer
            }
        }
        // The folder tree, for More Folders, Favorites and Move to, once per account per run.
        .task(id: store.selectedAccount?.id) {
            if let account = store.selectedAccount { await store.loadFolderTree(for: account.id) }
        }
        // A selection belongs to the list it was made in.
        .onChange(of: store.mailFolder) { _, _ in store.listActions.clearSelection() }
        .onChange(of: store.selectedAccount?.id) { _, _ in store.listActions.clearSelection() }
        .onChange(of: store.isSearchOpen) { _, _ in store.listActions.clearSelection() }
        .onChange(of: store.popoverTab) { _, _ in store.listActions.clearSelection() }
        .onAppear { applyListQCFlags() }
    }

    /// The folder whose rows are showing: a search's, or the one the menu picked.
    private var listFolder: MailFolder {
        store.isSearchOpen && store.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2
            ? store.searchFolder : store.mailFolder
    }

    /// Empty Deleted Items or Junk Email (M21), over the list. Asks first, with the count.
    private func emptyStrip(_ account: Account) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 4)
            Button {
                Task { await store.askToEmpty(store.mailFolder, in: account.id) }
            } label: {
                Label("Empty \(store.mailFolder.title)", systemImage: store.mailFolder == .deleted ? "trash.slash" : "xmark.bin")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Banners

    /// A failed action, and the one question the app ever asks about the mailbox: whether to
    /// create an Archive folder. Inline rather than an alert, which an `NSPopover` presents badly.
    @ViewBuilder
    private var banners: some View {
        // Undo Send's toast and a held send that failed (M24).
        ComposeBanners(store: store)
        // Automatic replies on, password expiring, mailbox almost full (2026-11-16).
        AccountHealthBanners(store: store)
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
        switch store.listActions.pending {
        case .empty(let folder, let accountID, let count)?:
            banner(symbol: "exclamationmark.triangle.fill", tint: .red,
                   text: folder == .deleted
                       ? "Permanently delete \(count) \(count == 1 ? "item" : "items") in Deleted Items?"
                       : "Move \(count) \(count == 1 ? "item" : "items") from Junk Email to Deleted Items?") {
                Button(folder == .deleted ? "Delete" : "Empty", role: .destructive) {
                    Task { await store.empty(folder, in: accountID) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Cancel") { store.listActions.pending = nil }
            }
        case .unsubscribe(let way, let sender, _)?:
            banner(symbol: "envelope.badge.shield.half.filled", tint: .accentColor,
                   text: Self.unsubscribeQuestion(way, sender: sender)) {
                Button("Unsubscribe") { Task { await store.confirmUnsubscribe() } }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { store.listActions.pending = nil }
            }
        case nil:
            EmptyView()
        }
        if let error = store.actionError {
            banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error) {
                Button("Dismiss") { store.actionError = nil }
            }
        }
    }

    static func unsubscribeQuestion(_ way: UnsubscribeLink.Preferred, sender: String) -> String {
        switch way {
        case .web(let url):
            return "Unsubscribe from \(sender)? Opens \(url.host ?? "their page") in your browser."
        case .mail(let mail):
            return "Unsubscribe from \(sender)? Sends \u{201C}\(mail.subject)\u{201D} to \(mail.address)."
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
            // folder and account menu.
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
                .help(store.draft?.hasContent == true ? "Back to the message you are writing" : "New Message  ⌘N")
                .accessibilityLabel("New message")
                .disabled(store.selectedAccount == nil)
                if store.selectedAccount != nil { accountMenu }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // Search belongs to Inbox and Sent, looking in whichever shows; on the Today tab it
                // leaves the row entirely rather
                // than leaving a hole. It goes and comes without a transition: animated, it slid
                // the icons beside it and the bar looked as if it changed height.
                if !showsTodayTab {
                    optionsMenu
                        .transition(.identity)
                    Button {
                        if store.isSearchOpen { store.closeSearch() } else { store.isSearchOpen = true }
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search \(store.mailFolder.title)  ⌘F")
                    .accessibilityLabel("Search \(store.mailFolder.title)")
                    .disabled(store.selectedAccount == nil)
                    .transition(.identity)
                }

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Settings  ⌘,")
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

    /// Inbox | Today, in the calendar's capsule style, the unread count on Inbox (M19). The mail
    /// tab names the folder the menu picked, "Sent" for Sent Items.
    private var tabSwitch: some View {
        HStack(spacing: 2) {
            tabButton(.inbox, key: "1") {
                HStack(spacing: 4) {
                    Text(store.mailFolder.tabTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 120)
                    let count = store.selectedAccount.map { store.unreadCount(for: $0.id) } ?? 0
                    if count > 0, store.mailFolder == .inbox {
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

    /// Outlook's Filter By and Sort By in one menu beside search (2026-11-16). The glyph fills
    /// while a filter is on, so a shortened list never passes for the whole folder.
    private var optionsMenu: some View {
        let folder = store.mailFolder
        let filtered = !store.listOptions.filters(in: folder).isEmpty
        return Menu {
            Section("Filter") {
                ForEach(MailFilter.allCases.filter { $0.applies(to: folder) }) { filter in
                    Toggle(isOn: Binding(get: { store.listOptions.filters.contains(filter) },
                                         set: { _ in store.toggleFilter(filter) })) {
                        Label(filter.title, systemImage: filter.symbol)
                    }
                }
                if filtered {
                    Button("Clear Filters") { store.listOptions.filters = [] }
                }
            }
            Section("Sort By") {
                Picker("Sort By", selection: $store.listOptions.sort) {
                    ForEach(MailSort.allCases) { sort in
                        Text(sort.title(in: folder)).tag(sort)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(filtered ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter and Sort")
        .accessibilityLabel("Filter and sort")
        .disabled(store.selectedAccount == nil)
    }

    /// Says which filters are on, with a way out, under the header.
    private var filterStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Showing \(store.listOptions.summary(in: store.mailFolder))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Clear") { store.listOptions.filters = [] }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// The menu on the left: the folder (the user's call, 2026-09-28: here, not a third tab),
    /// and with several accounts the account above it. It is named after the
    /// account when there are several, else after the folder.
    private var accountMenu: some View {
        Menu {
            if accounts.count > 1 {
                ForEach(accounts) { account in
                    Button {
                        select(account)
                    } label: {
                        let count = store.unreadCount(for: account.id)
                        Label(count > 0 ? "\(account.displayName)  (\(count))" : account.displayName,
                              systemImage: store.selectedAccount?.id == account.id ? "checkmark" : "")
                    }
                }
                Divider()
            }
            ForEach(MailFolder.standard, id: \.self) { folder in
                Button {
                    pick(folder)
                } label: {
                    Label(folder.title, systemImage: store.mailFolder == folder ? "checkmark" : "")
                }
            }
            if let account = store.selectedAccount { otherFolders(account) }
        } label: {
            HStack(spacing: 3) {
                Text(accounts.count > 1 ? (store.selectedAccount?.displayName ?? "") : store.mailFolder.title)
                    .font(.system(size: 11)).lineLimit(1)
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

    /// Favorites straight in the menu, the whole tree under More Folders, and a way to pin the
    /// custom folder showing (M21, after Outlook's Favorites).
    @ViewBuilder
    private func otherFolders(_ account: Account) -> some View {
        let favorites = store.listActions.favorites(for: account.id)
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { folder in
                    Button {
                        open(folder)
                    } label: {
                        Label(folder.name, systemImage: store.mailFolder == folder.mailFolder ? "checkmark" : "star")
                    }
                }
            }
        }
        Divider()
        Menu("More Folders") {
            switch store.listActions.folderTrees[account.id] {
            case .loaded(let folders)?:
                FolderTreeItems(folders: folders, checked: store.mailFolder) { open($0) }
            case .failed?:
                Button("Could Not Load Folders. Try Again") {
                    Task { await store.loadFolderTree(for: account.id, force: true) }
                }
            case .loading?, nil:
                Text("Loading Folders...")
            }
        }
        if case .custom(let folder) = store.mailFolder {
            let favorite = store.listActions.isFavorite(folder, accountID: account.id)
            Button(favorite ? "Remove \u{201C}\(folder.name)\u{201D} from Favorites" : "Add \u{201C}\(folder.name)\u{201D} to Favorites") {
                store.listActions.toggleFavorite(folder, accountID: account.id, persist: store.accounts.persists)
            }
        }
    }

    private func open(_ folder: MailboxFolder) {
        store.open(folder)
        if store.popoverTab == .today {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { store.popoverTab = .inbox }
        }
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
            if store.hasSearchInput {
                searchContent(account)
            } else if store.showsOptionsList {
                optionsContent(account)
            } else if store.mailFolder != .inbox {
                folderContent(store.mailFolder, account)
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
        SearchBarView(store: store, focused: $searchFocused)
    }

    /// Events, People and the mail found (`SearchResultsView`).
    private func searchContent(_ account: Account) -> some View {
        SearchResultsView(store: store, account: account, onOpenEvent: onOpenEvent)
    }

    /// The folder showing, filtered or reordered by the server. While the account itself is
    /// failing, the Inbox's own screen for that says so.
    @ViewBuilder
    private func optionsContent(_ account: Account) -> some View {
        let folder = store.mailFolder
        Group {
            switch store.state(for: account.id) {
            case .needsPassword, .passwordRejected, .unreachable, .failed:
                inboxContent(account)
            case .loading, .messages, .empty:
                switch store.optionsAccountID == account.id ? store.optionsPhase : .idle {
                case .idle, .searching:
                    SkeletonListView()
                case .results(let messages) where messages.isEmpty:
                    StatePlaceholder(symbol: "line.3.horizontal.decrease.circle", tint: .secondary,
                                     title: "No messages match",
                                     message: "Nothing in \(folder.title) of \(account.displayName) is \(store.listOptions.summary(in: folder).lowercased()).") {
                        Button("Clear Filters") { store.listOptions.filters = [] }
                    }
                case .results(let messages):
                    InboxListView(messages: messages, accountID: account.id, store: store, folder: folder,
                                  groupsByDate: store.listOptions.sort == .date)
                case .failed(let message):
                    GenericFailureView(message: message) { Task { await store.loadOptionsList() } }
                }
            }
        }
        // Again whenever the options, the folder or the account change, and after every poll,
        // so new mail that matches shows up as it does in the plain list.
        .task(id: "\(account.id) \(folder) \(store.listOptions.sort) \(store.listOptions.filters(in: folder).map(\.rawValue)) \(store.lastRefresh?.timeIntervalSince1970 ?? 0)") {
            await store.loadOptionsList()
        }
    }

    /// Any folder but the Inbox. While the account itself is failing (unreachable, password
    /// rejected) the Inbox's own screen for that says so, rather than a second, vaguer one.
    @ViewBuilder
    private func folderContent(_ folder: MailFolder, _ account: Account) -> some View {
        Group {
            switch store.state(for: account.id) {
            case .needsPassword, .passwordRejected, .unreachable, .failed:
                inboxContent(account)
            case .loading, .messages, .empty:
                switch store.list(folder, for: account.id) ?? .idle {
                case .idle, .searching:
                    SkeletonListView()
                case .results(let messages) where messages.isEmpty:
                    StatePlaceholder(symbol: folder.emptySymbol, tint: .secondary,
                                     title: folder.emptyTitle,
                                     message: "\(folder.title) of \(account.displayName) is empty.") {
                        EmptyView()
                    }
                case .results(let messages):
                    InboxListView(messages: messages, accountID: account.id, store: store, folder: folder,
                                  groupsByDate: true)
                case .failed(let message):
                    GenericFailureView(message: message) { Task { await store.loadFolder(folder, account.id) } }
                }
            }
        }
        .task(id: "\(account.id) \(folder)") { await store.loadFolder(folder, account.id) }
    }

    @ViewBuilder
    private func inboxContent(_ account: Account) -> some View {
        do {
            switch store.state(for: account.id) {
            case .loading:
                SkeletonListView()
            case .messages(let messages):
                InboxListView(messages: messages, accountID: account.id, store: store, groupsByDate: true)
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
            // While a check runs, the time gives way to a shimmering "Updating..." (osx-autoconnect's
            // status shimmer, the user's pick over a spinner); refresh sits beside the time
            // otherwise, not in the header (the user's call, 2026-09-25).
            if showsUpdating {
                ShimmerText(text: "Updating...")
            } else {
                if let last = store.lastRefresh {
                    Text("Updated \(last.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Not updated yet")
                }
                Button {
                    onRefresh()
                    if store.showsFolderList { Task { await store.loadFolder() } }
                    if store.showsOptionsList { Task { await store.loadOptionsList() } }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .keyboardShortcut("r", modifiers: .command)
                .help("Check for New Mail  ⌘R")
                .accessibilityLabel("Check for new mail")
                .frame(width: 12, height: 12)
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
        // Held for at least one pass of the shimmer, so a quick check does not flash it.
        .onChange(of: store.isRefreshing) { _, refreshing in
            if refreshing {
                updatingSince = Date()
                showsUpdating = true
            } else {
                let shown = Date().timeIntervalSince(updatingSince ?? .distantPast)
                Task {
                    if shown < 0.9 { try? await Task.sleep(for: .seconds(0.9 - shown)) }
                    if !store.isRefreshing { showsUpdating = false }
                }
            }
        }
        .onAppear { showsUpdating = store.isRefreshing }
    }

    // MARK: - Switching accounts

    /// A folder from the menu, which also brings the mail tab forward from Today.
    private func pick(_ folder: MailFolder) {
        store.mailFolder = folder
        if store.popoverTab == .today {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { store.popoverTab = .inbox }
        }
    }

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
        // On a row of the list: its swipe action (M20).
        if store.openMessage == nil, !store.isComposing, !showsTodayTab,
           let window = store.popoverWindow, event.window === window {
            return handleRowSwipe(event)
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

extension PopoverRootView {
    /// A swipe across the row under the pointer follows the fingers once it is clearly sideways
    /// (vertical ones stay the list's scroll), and acts when let go past the threshold. The
    /// side it goes picks the action (Settings, General); one the folder does not offer only
    /// gives a little.
    fileprivate func handleRowSwipe(_ event: NSEvent) -> Bool {
        let actions = store.listActions
        if event.phase.contains(.began) {
            rowSwipe.began()
            rowSwipeSideways = nil
            actions.swipingRow = actions.hoveredRow
            actions.swipeOffset = 0
            return false
        }
        guard let id = actions.swipingRow, let account = store.selectedAccount else { return false }
        if event.phase.contains(.changed) {
            rowSwipe.moved(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            if rowSwipeSideways == nil, abs(rowSwipe.sidewaysTravel) > 4 || abs(event.scrollingDeltaY) > 4 {
                rowSwipeSideways = rowSwipe.isSideways
            }
            guard rowSwipeSideways == true else { return false }
            let travel = rowSwipe.sidewaysTravel
            let action = travel < 0 ? SwipeAction.left() : SwipeAction.right()
            actions.swipeOffset = SwipeTracker.rubberBand(travel, limit: action.applies(in: listFolder) ? 150 : 12)
            return true
        }
        guard event.phase.contains(.ended) || event.phase.contains(.cancelled) else { return false }
        let sideways = rowSwipeSideways == true
        let offset = actions.swipeOffset
        _ = rowSwipe.ended(threshold: 0)
        rowSwipeSideways = nil
        let action = offset < 0 ? SwipeAction.left() : SwipeAction.right()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { actions.swipeOffset = 0 }
        if sideways, event.phase.contains(.ended), abs(offset) >= SwipeReveal.threshold,
           action.applies(in: listFolder), let message = store.message(id, in: account.id) {
            Task { await store.perform(action, on: message, in: account.id) }
        }
        return sideways
    }

    /// DEBUG launch flags for screenshots of this milestone's states, which need clicks.
    fileprivate func applyListQCFlags() {
        #if DEBUG
        guard let account = store.selectedAccount else { return }
        Task {
            if let name = QCFlags.openFolder {
                if let standard = MailFolder.standard.first(where: { $0.title.lowercased() == name.lowercased() || $0.tabTitle.lowercased() == name.lowercased() }) {
                    store.mailFolder = standard
                } else {
                    await store.loadFolderTree(for: account.id)
                    // The list's own task may have started the read; wait for it.
                    for _ in 0..<40 where store.listActions.folderTrees[account.id] == .loading {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if let found = store.listActions.folderTrees[account.id]?.folders.first(where: { $0.name == name }) {
                        store.open(found)
                        if QCFlags.favoriteFolder { store.listActions.toggleFavorite(found, accountID: account.id, persist: false) }
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1.2))
            let shown = store.mailFolder == .inbox ? store.state(for: account.id).messages
                : (store.list(store.mailFolder, for: account.id)?.messages ?? [])
            if let rows = QCFlags.selectRows {
                store.listActions.selection = Set(rows.compactMap { shown.indices.contains($0) ? shown[$0].id : nil })
            }
            if let (index, offset) = QCFlags.swipeRow, shown.indices.contains(index) {
                store.listActions.swipingRow = shown[index].id
                store.listActions.swipeOffset = offset
            }
            if let toast = QCFlags.showToast {
                store.listActions.toast = UndoToast(text: toast, accountID: account.id,
                                                    undo: .init(ids: [], back: .distinguished("inbox"), wasJunk: false, rows: [], folder: .inbox))
            }
            switch QCFlags.confirm {
            case "empty"?: await store.askToEmpty(store.mailFolder, in: account.id)
            case "unsubscribe"?:
                if let letter = shown.first(where: { $0.senderName == "Newsletter" }) {
                    await store.askToUnsubscribe(message: letter.id, in: account.id)
                }
            default: break
            }
        }
        #endif
    }
}

struct InboxListView: View {
    let messages: [MailMessage]
    let accountID: UUID
    @Bindable var store: MailStore
    var folder: MailFolder = .inbox
    var highlight: [String] = []
    /// Today, Yesterday, the weekdays, Last Week and so on, over a newest-first list
    /// (2026-11-16, after Outlook). Off for any other order, whose groups would mean nothing.
    var groupsByDate = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: groupsByDate ? [.sectionHeaders] : []) {
                if groupsByDate {
                    ForEach(MailDateGroup.sections(messages)) { section in
                        Section {
                            rows(section.messages, first: section.messages.first?.id == messages.first?.id)
                        } header: {
                            groupHeader(section.title)
                        }
                    }
                } else {
                    rows(messages, first: true)
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
        // File names and invitation times for the rows, one request each for all of them.
        .task(id: messages.map(\.id)) {
            await store.loadRowDetails(for: messages, accountID: accountID)
        }
    }

    @ViewBuilder
    private func rows(_ list: [MailMessage], first: Bool) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, message in
            if index > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    // The same inset on both sides as the row's own content, no special
                    // left indent (the user's call, 2026-09-25).
                    .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
            }
            MessageRowView(message: message, accountID: accountID, store: store,
                           folder: folder, highlight: highlight,
                           startsHovered: first && index == 0 && QCFlags.hoverFirstRow) {
                // Cmd-click toggles a row in the selection, Shift-click extends it (M20); a
                // plain click opens the message, as before.
                let flags = NSEvent.modifierFlags
                if store.listActions.click(message.id, command: flags.contains(.command),
                                           shift: flags.contains(.shift), order: messages.map(\.id)) { return }
                store.actionError = nil
                // A draft opens in the composer (M25).
                if folder == .drafts {
                    Task { await store.openDraft(message.id, in: accountID) }
                    return
                }
                store.openMessage = .init(accountID: accountID, messageID: message.id)
            }
            // A row that leaves (archived, deleted) fades and gives up its height, so the
            // rows below are seen to close the gap rather than teleporting up.
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }

    /// Pinned while its rows scroll under it, so it has the popover's own opaque surface.
    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MessageRowView.Metrics.horizontalPadding)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityAddTraits(.isHeader)
    }
}
