#if DEBUG
import AppKit
import SwiftUI

/// `--widget-preview` (DEBUG): the two widgets' faces in a window, drawn from the very file the
/// widget extension reads (`WidgetAgenda.read()`), so a screenshot proves both the faces and the
/// app's write. Sizes are macOS's small, medium and large widgets.
@MainActor
enum WidgetPreviewWindow {
    static var isRequested: Bool { CommandLine.arguments.contains("--widget-preview") }

    private static var window: NSWindow?

    static func show() {
        let view = WidgetPreviewGrid(agenda: WidgetAgenda.read(), now: Date())
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Widget Preview"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private struct WidgetPreviewGrid: View {
    let agenda: WidgetAgenda?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                tile(width: 170, height: 170) { UpNextWidgetView(agenda: agenda, now: now, size: .small) }
                tile(width: 364, height: 170) { UpNextWidgetView(agenda: agenda, now: now, size: .medium) }
                tile(width: 170, height: 170) { UpNextWidgetView(agenda: nil, now: now, size: .small) }
            }
            HStack(alignment: .top, spacing: 20) {
                tile(width: 364, height: 170) { AgendaWidgetView(agenda: agenda, now: now, size: .medium) }
                tile(width: 364, height: 382) { AgendaWidgetView(agenda: agenda, now: now, size: .large) }
            }
        }
        .padding(24)
        .background(Color(white: 0.55))
    }

    /// What the system draws around a widget: 16 pt margins on its background, rounded.
    private func tile<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: width, height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
