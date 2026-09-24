import Foundation

/// The refresh clock. Copied unchanged from osx-jirabar.
///
/// Deliberately not a `Timer`: a Timer scheduled on the main run loop does not fire while the Mac
/// is asleep and then fires immediately on wake, which is exactly the burst this is supposed to
/// avoid. A cancellable task loop makes pause and resume explicit.
///
/// This type owns no AppKit. The AppDelegate wires `NSWorkspace` sleep and wake notifications to
/// `pauseForSleep()` and `resumeFromWake()`, so the timing policy stays testable.
@MainActor
final class Poller {
    /// Returns true when the refresh succeeded, which resets the backoff.
    private let action: () async -> Bool
    private let intervalProvider: () -> TimeInterval

    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0

    private(set) var isRunning = false
    private(set) var isPausedForSleep = false

    /// Cap. Five minutes of base interval times four is twenty, which is long enough that a
    /// laptop off the VPN all afternoon costs almost nothing, and short enough that reconnecting
    /// heals within a coffee break.
    private nonisolated static let maxBackoffMultiplier = 4

    init(intervalProvider: @escaping () -> TimeInterval, action: @escaping () async -> Bool) {
        self.intervalProvider = intervalProvider
        self.action = action
    }

    /// Runs one refresh straight away, then keeps the loop going.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        isPausedForSleep = false
        scheduleLoop(fireImmediately: true)
    }

    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }

    /// One refresh now, and the interval starts again from this moment rather than from whenever
    /// the last tick happened.
    func refreshNow() {
        guard isRunning else { return }
        scheduleLoop(fireImmediately: true)
    }

    func pauseForSleep() {
        guard isRunning else { return }
        isPausedForSleep = true
        task?.cancel()
        task = nil
    }

    /// Exactly one refresh on wake, not one per tick that was missed while asleep.
    func resumeFromWake() {
        guard isRunning, isPausedForSleep else { return }
        isPausedForSleep = false
        scheduleLoop(fireImmediately: true)
    }

    /// The delay before the next tick. Grows while the host is unreachable and snaps back to the
    /// base interval the moment one request succeeds.
    var nextDelay: TimeInterval {
        Self.delay(base: intervalProvider(), consecutiveFailures: consecutiveFailures)
    }

    /// Pure, so the backoff curve can be tested without waiting on a real clock. `nonisolated`
    /// because it touches no state: it is arithmetic that happens to live on this type.
    nonisolated static func delay(base: TimeInterval, consecutiveFailures: Int) -> TimeInterval {
        let steps = max(0, min(consecutiveFailures, 16))
        let multiplier = min(1 << steps, maxBackoffMultiplier)
        return base * TimeInterval(multiplier)
    }

    private func scheduleLoop(fireImmediately: Bool) {
        task?.cancel()
        task = Task { [weak self] in
            var first = fireImmediately
            while !Task.isCancelled {
                guard let self else { return }
                if !first {
                    let delay = self.nextDelay
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                first = false
                let succeeded = await self.action()
                if Task.isCancelled { return }
                self.consecutiveFailures = succeeded ? 0 : min(self.consecutiveFailures + 1, 8)
            }
        }
    }
}
