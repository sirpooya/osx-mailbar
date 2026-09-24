import Testing
@testable import Mailbar

@Suite struct SmokeTests {
    @Test func testTargetLoadsTheApp() {
        #expect(Bool(true))
    }
}
