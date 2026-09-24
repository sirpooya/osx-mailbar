import SwiftUI

/// The one layout every non-list state uses, so the failures look deliberate rather than like
/// several different accidents. From osx-jirabar.
struct StatePlaceholder<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(tint)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}

/// No account yet. Onboarding, not a failure.
struct NoAccountsView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "envelope",
                         tint: .accentColor,
                         title: "Add your Exchange account",
                         message: "Enter the same server, user name and password Outlook uses, and your inbox shows up here.") {
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// The account exists but its Keychain item does not: deleted in Keychain Access, or a restore.
struct NeedsPasswordView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "key",
                         tint: .orange,
                         title: "Password missing",
                         message: "This account has no saved password. Enter it again in Settings.") {
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// 401. The password changed (a routine domain password rotation, usually) or was typed wrong.
/// Never rendered as an empty inbox.
struct PasswordRejectedView: View {
    let host: String
    let onOpenSettings: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "lock.trianglebadge.exclamationmark",
                         tint: .orange,
                         title: "Password not accepted",
                         message: "\(host) rejected the user name or password. If your password changed recently, update it in Settings.") {
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

struct UnreachableView: View {
    let host: String
    let reason: String
    let onRetry: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "wifi.exclamationmark",
                         tint: .orange,
                         title: "Cannot reach \(host)",
                         message: "\(reason) If the mail server is internal, check that you are on the company network or the VPN.") {
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}

/// The only state that means "no mail". Reached from a successful, genuinely empty inbox and
/// from nowhere else.
struct EmptyInboxView: View {
    let onRefresh: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "tray",
                         tint: .green,
                         title: "Your inbox is empty",
                         message: "Nothing in the Inbox right now.") {
            Button("Refresh", action: onRefresh)
                .controlSize(.small)
        }
    }
}

struct GenericFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        StatePlaceholder(symbol: "exclamationmark.triangle",
                         tint: .red,
                         title: "Something went wrong",
                         message: message) {
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
