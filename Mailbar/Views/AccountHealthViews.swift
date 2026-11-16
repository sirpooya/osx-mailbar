import SwiftUI

/// The popover's account-health banners: automatic replies on (with Turn Off), a password about
/// to expire, a mailbox almost full. Drawn like the popover's other banners.
struct AccountHealthBanners: View {
    let store: MailStore

    private let health = AccountHealth.shared

    var body: some View {
        ForEach(health.banners(for: store.accounts.accounts)) { banner in
            row(banner)
        }
        if let error = health.bannerError {
            line(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error) {
                Button("Dismiss") { health.bannerError = nil }
            }
        }
    }

    @ViewBuilder
    private func row(_ banner: AccountHealth.Banner) -> some View {
        switch banner.kind {
        case .autoReplies:
            line(symbol: "arrowshape.turn.up.left.fill", tint: .accentColor, text: banner.text) {
                if health.turningOff.contains(banner.accountID) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Button("Turn Off") {
                        guard let account = store.accounts.account(banner.accountID) else { return }
                        Task { await health.turnOffAutoReplies(for: account) }
                    }
                }
            }
        case .password:
            line(symbol: "key.fill", tint: .orange, text: banner.text) {
                Button("Dismiss") { health.dismiss(banner) }
            }
        case .quota:
            line(symbol: "externaldrive.fill.badge.exclamationmark", tint: .orange, text: banner.text) {
                Button("Dismiss") { health.dismiss(banner) }
            }
        }
    }

    private func line<Actions: View>(symbol: String, tint: Color, text: String,
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
}

/// Settings, Accounts: the account row's "..." menu, Automatic Replies and Activity Log, each
/// a sheet over Settings.
struct AccountRowMenu: View {
    let account: Account

    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case autoReplies, activityLog
        var id: String { rawValue }
    }

    var body: some View {
        Menu {
            Button("Automatic Replies...") { sheet = .autoReplies }
            Button("Activity Log...") { sheet = .activityLog }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for this account")
        .sheet(item: $sheet) { which in
            switch which {
            case .autoReplies: AutoReplySheet(account: account) { sheet = nil }
            case .activityLog: ActivityLogView(account: account) { sheet = nil }
            }
        }
        .onAppear {
            #if DEBUG
            // `--auto-replies-sheet` and `--activity-log` (DEBUG): open on the first account.
            guard account.id == FocusAccounts.all().first?.id || account.id == MockMode.accounts.first?.id,
                  sheet == nil else { return }
            if CommandLine.arguments.contains("--auto-replies-sheet") { sheet = .autoReplies }
            if CommandLine.arguments.contains("--activity-log") { sheet = .activityLog }
            #endif
        }
    }
}
