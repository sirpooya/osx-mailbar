import AppKit

/// Keeps the app out of the Dock, permanently, and brings it forward when a window needs focus.
///
/// osx-jirabar learned this: flipping to `.regular` while a window is open was never what made
/// text fields take the caret. A titled `NSWindow` can become key in an accessory app; what it
/// needs is the app activated. So the policy stays `.accessory` and focus is taken by activating.
@MainActor
enum WindowActivation {
    /// `ignoringOtherApps`, because an accessory app is not in the Cmd+Tab list and a polite
    /// request can be deferred until the user clicks, which reads as a field refusing typing.
    static func claim() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
