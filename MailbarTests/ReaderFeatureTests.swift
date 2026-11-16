import Foundation
import Testing
import WebKit
@testable import Mailbar

/// M22, the reader: find in the body, text size, the invitation's conflict line.
@Suite struct ReaderFeatureTests {
    private let nine = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, _ startMinutes: Double, _ endMinutes: Double, showAs: String = "Busy",
                       cancelled: Bool = false, response: String = "Accept", allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, changeKey: "", subject: id, start: nine.addingTimeInterval(startMinutes * 60),
                      end: nine.addingTimeInterval(endMinutes * 60), isAllDay: allDay, location: "", organizer: "",
                      isRecurring: false, isMeeting: true, isCancelled: cancelled, myResponse: response,
                      showAs: showAs, isPrivate: false)
    }

    // MARK: - Conflicts

    @Test func anOverlappingEventIsAConflictAndTheFirstByStartIsNamed() throws {
        let meeting = event("Planning", 60, 120)
        let conflict = try #require(MeetingCard.conflict(for: meeting, among: [
            event("Lunch", 90, 150), event("Design sync", 30, 90), event("Later", 200, 230),
        ]))
        #expect(conflict.kind == .overlap)
        #expect(conflict.event.subject == "Design sync")
        #expect(conflict.more == 1)
        #expect(conflict.text.hasPrefix("Conflicts with Design sync, "))
        #expect(conflict.text.hasSuffix(", and 1 more"))
    }

    @Test func anEventEndingAsTheMeetingStartsIsAdjacent() throws {
        let meeting = event("Planning", 60, 120)
        let conflict = try #require(MeetingCard.conflict(for: meeting, among: [event("Core Weekly", 0, 60)]))
        #expect(conflict.kind == .adjacent)
        #expect(conflict.text.hasPrefix("Adjacent to Core Weekly, "))
        #expect(!conflict.text.contains("more"))
        // An overlap wins over a touch.
        let both = try #require(MeetingCard.conflict(for: meeting, among: [event("Core Weekly", 0, 60), event("Sync", 100, 130)]))
        #expect(both.kind == .overlap)
        #expect(both.event.subject == "Sync")
    }

    @Test func freeCancelledAndDeclinedEventsNeverConflict() {
        let meeting = event("Planning", 60, 120)
        #expect(MeetingCard.conflict(for: meeting, among: [
            event("Holiday", 0, 1440, showAs: "Free", allDay: true),
            event("Away desk", 60, 120, showAs: "WorkingElsewhere"),
            event("Gone", 60, 120, cancelled: true),
            event("No", 60, 120, response: "Decline"),
            event("Before", 0, 30), event("After", 150, 180),
        ]) == nil)
    }

    @Test func anAllDayBusyEventSaysAllDay() throws {
        let meeting = event("Planning", 60, 120)
        let conflict = try #require(MeetingCard.conflict(for: meeting, among: [event("Offsite", -540, 900, allDay: true)]))
        #expect(conflict.text == "Conflicts with Offsite, all day")
    }

    // MARK: - Find and zoom

    @Test func findCountReadsLikeSafari() {
        #expect(ReaderFind.countLabel(index: 1, total: 7, query: "review") == "2 of 7")
        #expect(ReaderFind.countLabel(index: 0, total: 0, query: "review") == "No matches")
        #expect(ReaderFind.countLabel(index: 0, total: 0, query: "  ") == "")
        #expect(ReaderFind.step(6, by: 1, total: 7) == 0)
        #expect(ReaderFind.step(0, by: -1, total: 7) == 6)
        #expect(ReaderFind.step(0, by: 1, total: 0) == 0)
    }

    @Test func zoomStepsLikeABrowserAndSitsOnTopOfTheFit() {
        #expect(ReaderZoom.larger(than: 1) == 1.1)
        #expect(ReaderZoom.smaller(than: 1) == 0.9)
        #expect(ReaderZoom.larger(than: 3) == 3)
        #expect(ReaderZoom.smaller(than: 0.5) == 0.5)
        #expect(ReaderZoom.label(1.25) == "125%")
        #expect(ReaderZoom.pageZoom(fit: 0.8, user: 1.25) == 1.0)
    }

    /// The scripts against a real page, in the app's own world with the page's script off, as the
    /// reader runs them: matches marked across case and the Persian ye, the current one moved,
    /// the marks taken out again with the text unchanged, and the selection read back.
    @MainActor @Test func findMarksStepsAndClearsInARealPage() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let html = "<html><body><p id='a'>Review the <b>review</b> notes. REVIEW again.</p><p dir='rtl'>بررس\u{064A} و بررس\u{06CC}</p></body></html>"
        view.loadHTMLString(html, baseURL: nil)
        for _ in 0..<100 where view.isLoading || view.url == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))
        func run(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
            try await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
        }
        #expect((try await run(ReaderFind.markScript, ["query": "review"]) as? NSNumber)?.intValue == 3)
        // The Arabic ye and the Persian ye are one letter to find.
        #expect((try await run(ReaderFind.markScript, ["query": "بررس\u{06CC}"]) as? NSNumber)?.intValue == 2)
        #expect((try await run(ReaderFind.selectScript, ["index": 1]) as? NSNumber)?.intValue == 2)
        let current = try await run("return document.querySelectorAll('mark[data-mailbar-find]')[1].style.background;") as? String
        #expect(current?.contains("255, 159, 10") == true)
        #expect((try await run(ReaderFind.clearScript) as? NSNumber)?.intValue == 2)
        let text = try await run("return document.body.innerText;") as? String
        #expect(text?.contains("Review the review notes. REVIEW again.") == true)
        #expect((try await run("return document.querySelectorAll('mark').length;") as? NSNumber)?.intValue == 0)
        _ = try await run("const r = document.createRange(); r.selectNodeContents(document.querySelector('b')); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); return 0;")
        #expect(try await run(ReaderFind.selectionScript) as? String == "review")
    }
}
