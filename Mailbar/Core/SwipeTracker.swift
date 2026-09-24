import CoreGraphics
import Foundation

enum SwipeDirection {
    case left
    case right
}

/// Accumulates a trackpad swipe across the scroll events it arrives as, and says which way it went
/// once it is over.
///
/// It exists because the obvious version does not work. A swipe is a run of `.scrollWheel` events
/// with a phase, and the `.began` and `.ended` events carry **zero deltas**: they are markers, not
/// movement. Testing each event for "is this more sideways than vertical" therefore rejects the
/// `.ended` event, `0 > 0` being false, and the gesture never completes. The direction has to be
/// judged from the whole gesture's travel, once, at the end.
struct SwipeTracker {
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0

    mutating func began() {
        travelX = 0
        travelY = 0
    }

    mutating func moved(deltaX: CGFloat, deltaY: CGFloat) {
        travelX += deltaX
        travelY += deltaY
    }

    /// How far sideways the gesture has come so far, for showing it as it happens.
    var sidewaysTravel: CGFloat { travelX }

    /// True while the gesture is more sideways than vertical, so the panel only follows a swipe
    /// that is actually going sideways and stays put while the list is being scrolled.
    var isSideways: Bool { abs(travelX) > abs(travelY) }

    /// The direction this swipe counts as, or nil when it was too small or mostly vertical.
    /// Resets either way, so the next swipe starts clean even if this one did nothing.
    mutating func ended(threshold: CGFloat) -> SwipeDirection? {
        let x = travelX
        let y = travelY
        travelX = 0
        travelY = 0

        guard abs(x) > threshold, abs(x) > abs(y) else { return nil }
        return x > 0 ? .right : .left
    }

    /// How far the panel moves for a given amount of finger travel.
    ///
    /// It follows the swipe but never goes far, easing towards `limit` and never past it, so the
    /// panel acknowledges the gesture without opening a gap where the next account's inbox would
    /// be if they were loaded. Pulling against the last account gets a smaller limit, which is
    /// how a boundary says no.
    static func rubberBand(_ travel: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        return limit * tanh(travel / limit)
    }

    /// For a mouse wheel or any device that reports no phases at all: one decisive push, judged
    /// on its own.
    static func direction(ofUnphasedDeltaX deltaX: CGFloat,
                          deltaY: CGFloat,
                          threshold: CGFloat) -> SwipeDirection? {
        guard abs(deltaX) > threshold, abs(deltaX) > abs(deltaY) else { return nil }
        return deltaX > 0 ? .right : .left
    }
}
