import AppKit
import Observation
import SwiftUI

/// Swiping between weeks the way Apple's Calendar does (2026-09-25): the previous, current and
/// next page sit side by side, the strip follows the fingers while they move, and on release a
/// spring carries it on to the neighbour or back, judged by how far and how fast the swipe went.
/// "Swipe slowly to stop between weeks" (Apple's Calendar guide) is the feel being matched.
///
/// The fade-and-slide transition this replaces only moved after the fingers had lifted, rebuilt
/// the whole grid mid-animation, and slid in a week without events: that was the jank.
///
/// After a committed swipe the strip is at exactly one page to the side, which shows the same
/// days the new page 0 will show, so resetting the offset to zero while the anchor moves by one is
/// invisible. Its events were fetched ahead (`CalendarStore.fetchRange`), so nothing fills in.
@MainActor
@Observable
final class CalendarPager {
    /// Points the strip is dragged from rest: negative toward the next page.
    var offset: CGFloat = 0
    /// One page's width, measured by the strip.
    var width: CGFloat = 800
    private(set) var isSettling = false

    @ObservationIgnored var onCommit: ((Bool) -> Void)?
    @ObservationIgnored private var samples: [(time: TimeInterval, dx: CGFloat)] = []

    // MARK: - Following the fingers

    func began() {
        samples.removeAll()
    }

    func moved(by dx: CGFloat, at time: TimeInterval) {
        guard !isSettling else { return }
        offset += dx
        samples.append((time, dx))
        samples.removeAll { time - $0.time > 0.08 }
    }

    /// Commits when the strip went a third of a page, or when it was flicked; springs back
    /// otherwise.
    func ended(at time: TimeInterval) {
        guard !isSettling else { return }
        // Speed over the last 80 ms, measured up to the release. Fingers that rested before
        // lifting have no recent samples, and a rest is a speed of zero, not a flick.
        let recent = samples.filter { time - $0.time <= 0.08 }
        let velocity: CGFloat
        if let first = recent.first {
            let span = max(time - first.time, 1.0 / 120)
            velocity = recent.reduce(0) { $0 + $1.dx } / CGFloat(span)   // points per second
        } else {
            velocity = 0
        }
        samples.removeAll()

        let flicked = abs(velocity) > 350
        let far = abs(offset) > width / 3
        if far || flicked {
            // A flick decides by its own direction, even against a short drag the other way.
            let forward = flicked ? velocity < 0 : offset < 0
            settle(forward: forward, velocity: velocity)
        } else {
            settle(forward: nil, velocity: velocity)
        }
    }

    // MARK: - Settling

    /// Springs to the next page (`true`), the previous (`false`), or back to rest (`nil`).
    func settle(forward: Bool?, velocity: CGFloat = 0) {
        guard !isSettling else { return }
        isSettling = true
        let target: CGFloat = forward.map { $0 ? -width : width } ?? 0
        // The spring starts at the fingers' own speed, so the hand-off from dragging to settling
        // has no step in it.
        let distance = target - offset
        let initial = abs(distance) > 1 ? Double(velocity / distance) : 0
        let animation = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 32,
                                                      initialVelocity: min(max(initial, 0), 12))
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            offset = target
        } completion: { [weak self] in
            guard let self else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                if let forward { self.onCommit?(forward) }
                self.offset = 0
            }
            self.isSettling = false
        }
    }
}

/// A trackpad swipe turned into paging, for the popover's Today tab: the first few points decide
/// the axis, sideways events then drive the pager and are consumed so the hours do not also
/// scroll, and the momentum after a sideways swipe is swallowed. The calendar window does the
/// same in `CalendarWindow.handleSwipe`.
@MainActor
final class PagerSwipe {
    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var travel = CGSize.zero

    /// True when the event was used for paging and must not reach the scroll view.
    func handle(_ event: NSEvent, pager: CalendarPager) -> Bool {
        let time = event.timestamp
        if !event.momentumPhase.isEmpty { return axis == .horizontal }
        if event.phase.contains(.began) {
            axis = .undecided
            travel = .zero
            pager.began()
            return false
        }
        if event.phase.contains(.changed) {
            if axis == .undecided {
                travel.width += event.scrollingDeltaX
                travel.height += event.scrollingDeltaY
                guard abs(travel.width) + abs(travel.height) > 4 else { return false }
                axis = abs(travel.width) > abs(travel.height) ? .horizontal : .vertical
                if axis == .horizontal { pager.moved(by: travel.width, at: time) }
                return axis == .horizontal
            }
            guard axis == .horizontal else { return false }
            pager.moved(by: event.scrollingDeltaX, at: time)
            return true
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            defer { if axis != .horizontal { axis = .undecided } }
            guard axis == .horizontal else { return false }
            pager.ended(at: time)
            return true
        }
        // A mouse with a sideways wheel sends no phases: one decisive push is one page.
        if event.phase.isEmpty,
           let direction = SwipeTracker.direction(ofUnphasedDeltaX: event.scrollingDeltaX,
                                                  deltaY: event.scrollingDeltaY, threshold: 40) {
            pager.settle(forward: direction == .left)
            return true
        }
        return false
    }
}

/// Three pages side by side, -1, 0 and 1, offset by the pager. Used for the header, the all-day
/// strip and the hour grid alike, so all three move as one.
struct PagerStrip<Page: View>: View {
    let pager: CalendarPager
    let measures: Bool
    @ViewBuilder let page: (Int) -> Page

    init(pager: CalendarPager, measures: Bool = false, @ViewBuilder page: @escaping (Int) -> Page) {
        self.pager = pager
        self.measures = measures
        self.page = page
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                ForEach(-1...1, id: \.self) { index in
                    page(index).frame(width: width, height: proxy.size.height)
                }
            }
            .offset(x: -width + pager.offset)
            .onAppear { if measures { pager.width = width } }
            .onChange(of: width) { _, new in if measures { pager.width = new } }
        }
        .clipped()
    }
}

/// The calendar's surfaces, kept free of any colour cast (the user's call, 2026-09-25).
///
/// `windowBackgroundColor` is tinted by the desktop wallpaper on current macOS ("wallpaper
/// tinting in windows"), so a grey laid over it came out warm. The calendar sits on the text
/// background instead, which is never tinted: pure white in light mode, pure dark in dark mode.
/// The shading is then an exact neutral grey on top: black at a few percent in light, white in
/// dark, no hue at all.
enum CalendarSurface {
    static let background = Color(nsColor: .textBackgroundColor)

    static let shade = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Lighter again (the user's call, 2026-09-25): the weekend and off hours only just grey.
        return dark ? NSColor(white: 1, alpha: 0.035) : NSColor(white: 0, alpha: 0.028)
    })
}
