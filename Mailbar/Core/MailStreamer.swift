import Foundation
import Network

/// Instant new mail (M11): an EWS streaming subscription per account.
///
/// Per account, one loop: subscribe to the inbox, open `GetStreamingEvents` for up to 29 minutes,
/// and read the envelopes the server writes. Any event means the inbox changed, so the app
/// refreshes at once instead of waiting for the next poll. When the server closes the connection
/// (its timeout), the loop reopens it with the same subscription; when the subscription is gone,
/// it subscribes again.
///
/// Cheaper than polling as well as faster: between events the connection is idle, so a quiet
/// inbox costs one reconnect per half hour instead of two requests every two minutes. While every
/// account is streaming, the poller slows to `fallbackPollInterval` as a safety net in case a
/// subscription dies without the connection noticing.
///
/// Failure rules:
/// - A rejected password stops streaming for that account until its settings change. Every retry
///   would be one more failed logon against the domain's lockout counter.
/// - A server that cannot stream (older than Exchange 2010 SP1, or EWS notifications turned off)
///   is left to polling for the rest of the session.
/// - Anything else (VPN down, timeout) backs off 5 s, 10 s, 20 s ... up to 5 minutes, and a network
///   change (the VPN coming back) reconnects straight away.
@MainActor
final class MailStreamer {
    private let store: MailStore
    private let onChange: () -> Void

    private var loops: [UUID: Task<Void, Never>] = [:]
    /// Accounts whose stream is open right now.
    private(set) var live: Set<UUID> = []
    /// Accounts that will not stream this session: old server, or a rejected password.
    private var parked: [UUID: String] = [:]
    private var changeTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastInterfaces: [String] = []

    /// The poll interval while every account is streaming.
    static let fallbackPollInterval: TimeInterval = 10 * 60
    /// Under EWS's 30-minute cap, so the server's own Closed envelope is what ends a connection.
    static let connectionMinutes = 29

    init(store: MailStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    /// True when every account has an open stream, which is when polling can relax.
    var coversAllAccounts: Bool {
        let ids = Set(store.accounts.accounts.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: live)
    }

    // MARK: - Lifecycle

    func start() {
        startMonitoringNetwork()
        sync()
    }

    /// Starts a loop for every account that has none, and ends the loops of deleted accounts.
    func sync() {
        let ids = Set(store.accounts.accounts.map(\.id))
        for (id, loop) in loops where !ids.contains(id) {
            loop.cancel()
            loops[id] = nil
            live.remove(id)
        }
        for id in ids where loops[id] == nil && parked[id] == nil {
            loops[id] = Task { [weak self] in await self?.run(id) }
        }
    }

    /// For account edits: a new password or server deserves a fresh try, parked or not.
    func restartAll() {
        stopLoops()
        parked.removeAll()
        sync()
    }

    /// Sleep: close every connection. Wake calls `sync` again.
    func stopLoops() {
        for loop in loops.values { loop.cancel() }
        loops.removeAll()
        live.removeAll()
    }

    // MARK: - One account

    private func run(_ id: UUID) async {
        var subscription: String?
        var failures = 0
        var connectedBefore = false

        while !Task.isCancelled {
            if let version = store.serverVersion(id), version.major < 14 {
                park(id, "Exchange \(version.major) cannot stream; polling instead.")
                return
            }
            guard let (url, credential) = store.connection(for: id) else {
                // No password yet. Settings will call restartAll once there is one.
                park(id, "No password saved.")
                return
            }
            do {
                if subscription == nil {
                    subscription = try await store.client.subscribeToInbox(at: url, credential: credential)
                }
                let events = try await store.client.streamInboxEvents(
                    subscription: subscription!, minutes: Self.connectionMinutes, at: url, credential: credential)
                live.insert(id)
                let opened = Date()
                // Anything that happened while the connection was down was not streamed, so a
                // reconnect catches up with one refresh. The very first connection does not need
                // to: the launch poll just ran.
                if connectedBefore { changed() }
                connectedBefore = true
                log("\(id.uuidString.prefix(8)) streaming")

                for try await chunk in events {
                    if chunk.hasChanges { changed() }
                    if chunk.subscriptionIsGone { subscription = nil; break }
                    if chunk.isClosed { break }
                    if chunk.errorCode != nil { throw EWSError.server(chunk.errorCode ?? "Error") }
                }
                live.remove(id)
                // A connection the server ends at once, over and over, must not become a tight
                // reconnect loop: short-lived counts as a failure and backs off.
                if Date().timeIntervalSince(opened) < 5 {
                    failures += 1
                    try? await Task.sleep(nanoseconds: UInt64(min(5 * pow(2, Double(failures - 1)), 300) * 1_000_000_000))
                } else {
                    failures = 0
                }
            } catch is CancellationError {
                live.remove(id)
                return
            } catch EWSError.passwordRejected {
                live.remove(id)
                park(id, "Password rejected; not retrying until the account changes.")
                return
            } catch EWSError.server(let message) where subscription == nil {
                // Subscribe itself was refused: this server does not stream for this mailbox.
                live.remove(id)
                park(id, "Subscribe refused (\(message)); polling instead.")
                return
            } catch {
                live.remove(id)
                subscription = error is EWSError ? nil : subscription
                failures += 1
                let delay = min(5 * pow(2, Double(failures - 1)), 300)
                log("\(id.uuidString.prefix(8)) stream dropped (\(error)); retry in \(Int(delay)) s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func park(_ id: UUID, _ reason: String) {
        parked[id] = reason
        loops[id] = nil
        live.remove(id)
        log("\(id.uuidString.prefix(8)) \(reason)")
    }

    /// Coalesces a burst of events (a message arriving is often New plus Created plus Modified)
    /// into one refresh.
    private func changed() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    // MARK: - Network changes

    /// A VPN coming up adds an interface; Wi-Fi coming back makes the path satisfied again.
    /// Either way the loops that are backing off should try now, not in five minutes.
    private func startMonitoringNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.map(\.name).sorted()
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(interfaces: interfaces, satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "in.pooya.mailbar.path"))
        pathMonitor = monitor
    }

    private func networkChanged(interfaces: [String], satisfied: Bool) {
        defer { lastInterfaces = interfaces }
        guard satisfied, !lastInterfaces.isEmpty, interfaces != lastInterfaces else { return }
        log("network changed, reconnecting")
        stopLoops()
        // Parked accounts stay parked: a new network does not fix a rejected password.
        sync()
    }

    private func log(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[stream] \(message)\n".utf8))
        #endif
    }
}
