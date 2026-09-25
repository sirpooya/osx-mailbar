import AppKit
import SwiftUI

/// A zero-size view that takes first responder when its window appears, so a sheet opens with
/// no text field focused or selected, not even for a frame (the account editor, the event
/// form). Clearing focus afterwards instead let AppKit flash the first field selected.
/// Clicking or tabbing into a field works as usual.
struct FocusSink: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SinkView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            window.makeFirstResponder(self)
        }
    }
}
