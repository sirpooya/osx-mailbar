import Foundation
import ServiceManagement

/// Registers the app as a login item through `SMAppService` (M10). From osx-jirabar.
///
/// Only works from a bundled `.app`, which is why the installed copy in /Applications is the one
/// to toggle it from. `.requiresApproval` means macOS is waiting for the user in System Settings,
/// and re-registering will not change that, so the caller writes reality back into the switch
/// instead of leaving it showing what was asked for.
@MainActor
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns an explanation when it could not be done, so the UI can say why instead of
    /// silently reverting a switch the user just flipped.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if needsApproval {
                    return "Allow Mailbar in System Settings, General, Login Items, to finish turning this on."
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
