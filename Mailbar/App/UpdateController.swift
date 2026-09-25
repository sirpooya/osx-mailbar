import AppKit
import Sparkle

/// Sparkle, after osx-flipoff's `UpdateController`: one `SPUStandardUpdaterController` for the
/// process, checking the feed in Info.plist (`SUFeedURL`, appcast.xml on this repo's main) once a
/// day and on "Check for Updates..." in the tray menu. An update installs only if its zip carries
/// an EdDSA signature matching `SUPublicEDKey`; that, not notarization, is the trust anchor.
///
/// Release builds only. A Debug build has its own bundle id and mock data, and must never offer
/// to replace itself with the shipped app.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private var updaterController: SPUStandardUpdaterController?

    /// Starts the scheduled checks. Called once at launch.
    func start() {
        guard Self.isEnabled, updaterController == nil else { return }
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: self)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    /// The app is `LSUIElement`, so Sparkle's windows would open behind everything, unfocused.
    /// It is a regular app while one shows (osx-flipoff's fix).
    nonisolated func standardUserDriverWillShowModalAlert() {
        Task { @MainActor in
            DockPresence.windowOpened()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverDidShowModalAlert() {}

    /// Back to menu bar only, unless the calendar or Settings is still open.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in DockPresence.windowClosed() }
    }
}
