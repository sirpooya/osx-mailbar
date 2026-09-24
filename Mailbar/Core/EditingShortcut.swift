import Foundation

/// The standard editing shortcuts, matched by **virtual key code** and never by the character the
/// key produces.
///
/// 2026-09-09. Both paste paths used to match `charactersIgnoringModifiers` against `"v"`. That
/// string is not the key, it is whatever the ACTIVE INPUT SOURCE prints on the key, so with the
/// Persian layout selected Cmd+V reports a Persian letter, matches nothing, and paste, copy, cut,
/// select all and undo all stop working. Nothing logs, nothing errors: the event simply falls
/// through both the key monitor and `performKeyEquivalent` and lands on a main menu this app does
/// not really have.
///
/// It was reported as "pasting an image only works when the text field is empty", which is the
/// same bug wearing a disguise: the box had text because the person had switched to the Persian
/// layout to write it, and the layout was what broke the paste. Anything that reproduces "only
/// when I have already typed something" is worth testing with a second input source.
///
/// Virtual key codes are positional. They do not move with the layout, and they are how AppKit
/// resolves menu key equivalents itself, which is why Cmd+V in a normal app keeps working when
/// you switch layouts.
enum EditingShortcut: Equatable, CaseIterable {
    case selectAll
    case undo
    case redo
    case cut
    case copy
    case paste

    // kVK_ANSI_* from Carbon's Events.h. Positional codes for the QWERTY positions, whatever the
    // active layout draws on those keys.
    private static let keyA: UInt16 = 0x00
    private static let keyZ: UInt16 = 0x06
    private static let keyX: UInt16 = 0x07
    private static let keyC: UInt16 = 0x08
    private static let keyV: UInt16 = 0x09

    /// Command is required, and shift only ever distinguishes redo from undo. Any other modifier
    /// combination is somebody else's shortcut and must be left alone.
    static func match(keyCode: UInt16, command: Bool, shift: Bool) -> EditingShortcut? {
        guard command else { return nil }
        switch (keyCode, shift) {
        case (keyV, false): return .paste
        case (keyC, false): return .copy
        case (keyX, false): return .cut
        case (keyA, false): return .selectAll
        case (keyZ, false): return .undo
        case (keyZ, true): return .redo
        default: return nil
        }
    }

    /// The AppKit action this sends. A string because the selectors live in AppKit and this file
    /// deliberately does not import it.
    var selectorName: String {
        switch self {
        case .selectAll: return "selectAll:"
        case .undo: return "undo:"
        case .redo: return "redo:"
        case .cut: return "cut:"
        case .copy: return "copy:"
        case .paste: return "paste:"
        }
    }
}
