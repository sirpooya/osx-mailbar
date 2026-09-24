import Foundation
import Testing
@testable import Mailbar

@Suite struct RelativeTimeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tehran")!
        return calendar
    }
    private let locale = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func label(_ date: Date, now: Date) -> String {
        RelativeTime.label(for: date, now: now, calendar: calendar, locale: locale)
    }

    @Test func todayShowsTheTime() {
        let now = date(2026, 9, 24, 21, 0)
        #expect(label(date(2026, 9, 24, 9, 5), now: now) == "9:05\u{202F}AM")
    }

    @Test func lateLastNightIsYesterdayJustAfterMidnight() {
        #expect(label(date(2026, 9, 23, 23, 50), now: date(2026, 9, 24, 0, 10)) == "Yesterday")
    }

    @Test func twoToSixDaysAreCounted() {
        let now = date(2026, 9, 24)
        #expect(label(date(2026, 9, 22), now: now) == "2 days ago")
        #expect(label(date(2026, 9, 18), now: now) == "6 days ago")
    }

    @Test func aWeekOrMoreIsADate() {
        let now = date(2026, 9, 24)
        #expect(label(date(2026, 9, 17), now: now) == "Sep 17")
    }

    @Test func anotherYearCarriesTheYear() {
        #expect(label(date(2025, 9, 9), now: date(2026, 9, 24)) == "Sep 9, 2025")
    }

    @Test func aFutureTimestampIsToday() {
        let now = date(2026, 9, 24, 12, 0)
        #expect(label(date(2026, 9, 25, 1, 0), now: now) == "1:00\u{202F}AM")
    }
}

@Suite struct TextDirectionTests {
    @Test func persianIsRightToLeft() {
        #expect(TextDirection.firstStrong(in: "یادآوری: ارزیابی") == .rightToLeft)
    }

    @Test func leadingDigitsAndPunctuationDoNotDecide() {
        #expect(TextDirection.firstStrong(in: "2417 - ساخت شبانه") == .rightToLeft)
        #expect(TextDirection.firstStrong(in: "Re: هماهنگی") == .leftToRight)
    }
}

@Suite struct InboxStateTests {
    private let everyError: [EWSError] = [
        .passwordRejected, .unreachable("x"), .tlsFailure("x"), .notEWS("x"),
        .server("x"), .invalidResponse("x"), .unexpected("x"),
    ]

    /// The rule this app exists to get right: no failure is ever an empty inbox.
    @Test func noErrorEverBecomesTheEmptyInbox() {
        for error in everyError {
            let state = InboxState.from(error, host: "mail.example.com")
            #expect(state != .empty, "\(error) rendered as the empty inbox")
            #expect(state.messages.isEmpty)
            #expect(!state.isHealthy)
        }
    }

    @Test func zeroMessagesIsEmptyAndAnyIsMessages() {
        #expect(InboxState.from([]) == .empty)
        let message = MailMessage(id: "1", changeKey: "k", senderName: "A", senderAddress: "",
                                  subject: "S", preview: "", received: Date(),
                                  isRead: false, isFlagged: false, hasAttachments: false)
        #expect(InboxState.from([message]) == .messages([message]))
    }
}

/// Fails every request after the first `succeed` ones, or hangs until cancelled.
private final class ScriptedTransport: EWSTransport, @unchecked Sendable {
    enum Behaviour { case inbox, reject, hang }
    var behaviour: Behaviour

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func send(_ body: Data, to url: URL, credential: EWSCredential) async throws -> (Data, Int) {
        switch behaviour {
        case .reject:
            return (Data(), 401)
        case .hang:
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return (Data(), 500)
        case .inbox:
            let request = String(decoding: body, as: UTF8.self)
            if request.contains("<m:GetFolder>") {
                return (Data(MockFixtures.getFolder(unread: 3).utf8), 200)
            }
            return (Data(MockFixtures.findItem(MockFixtures.workInbox).utf8), 200)
        }
    }
}

@MainActor
@Suite struct MailStoreTests {
    private let account = Account(label: "Work", email: "someone@example.com",
                                  serverURL: "https://mail.example.com/EWS/Exchange.asmx",
                                  username: "someone")

    private func makeStore(_ transport: ScriptedTransport, password: String? = "pw") -> MailStore {
        let passwords = MemoryPasswordStore(password.map { [account.id: $0] } ?? [:])
        let accounts = AccountStore(inMemory: [account], passwords: passwords)
        return MailStore(accounts: accounts, client: EWSClient(transport: transport))
    }

    @Test func aSuccessfulPollFillsTheInboxAndTheCount() async {
        let store = makeStore(ScriptedTransport(.inbox))
        #expect(await store.refresh())
        #expect(store.state(for: account.id).messages.count == MockFixtures.workInbox.count)
        #expect(store.totalUnread == 3)
        #expect(!store.hasProblem)
        #expect(store.lastRefresh != nil)
    }

    @Test func aRejectedPasswordCountsZeroAndFlagsAProblem() async {
        let transport = ScriptedTransport(.inbox)
        let store = makeStore(transport)
        await store.refresh()
        transport.behaviour = .reject

        #expect(await store.refresh() == false)
        #expect(store.state(for: account.id) == .passwordRejected)
        #expect(store.totalUnread == 0)
        #expect(store.hasProblem)
    }

    @Test func aMissingPasswordIsItsOwnState() async {
        let store = makeStore(ScriptedTransport(.inbox), password: nil)
        #expect(await store.refresh() == false)
        #expect(store.state(for: account.id) == .needsPassword)
    }

    @Test func aCancelledPollLeavesTheListAlone() async {
        let transport = ScriptedTransport(.inbox)
        let store = makeStore(transport)
        await store.refresh()
        let before = store.state(for: account.id)

        transport.behaviour = .hang
        let task = Task { await store.refresh() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.value

        #expect(store.state(for: account.id) == before)
    }
}
