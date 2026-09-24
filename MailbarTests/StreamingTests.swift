import Foundation
import Testing
@testable import Mailbar

/// M11: streaming notifications.
@Suite struct StreamingParsingTests {
    @Test func envelopeEndsAreFoundWhateverThePrefix() {
        #expect(EnvelopeSplitter.endsWithClosingEnvelope(Data("<s:Envelope>x</s:Envelope>".utf8)))
        #expect(EnvelopeSplitter.endsWithClosingEnvelope(Data("<Envelope>x</Envelope>".utf8)))
        #expect(!EnvelopeSplitter.endsWithClosingEnvelope(Data("<s:Envelope><s:Body>".utf8)))
        #expect(!EnvelopeSplitter.endsWithClosingEnvelope(Data("<Envelope>x</NotAnEnvelope>".utf8)))
    }

    @Test func aKeepAliveIsNotAChange() {
        let chunk = EWSResponse.streamingChunk(from: Data(MockFixtures.streamingEnvelope(event: nil).utf8))
        #expect(chunk == StreamingChunk())
    }

    @Test func newMailIsAChange() {
        let chunk = EWSResponse.streamingChunk(from: Data(MockFixtures.streamingEnvelope(event: "NewMailEvent").utf8))
        #expect(chunk.hasChanges)
        #expect(!chunk.isClosed)
    }

    @Test func theServersTimeoutIsClosed() {
        let chunk = EWSResponse.streamingChunk(from: Data(MockFixtures.streamingEnvelope(event: nil, closed: true).utf8))
        #expect(chunk.isClosed)
        #expect(!chunk.hasChanges)
    }

    @Test func aLostSubscriptionAsksForANewOne() {
        let xml = """
        <Envelope><Body><GetStreamingEventsResponse><ResponseMessages>
        <GetStreamingEventsResponseMessage ResponseClass="Error">
        <MessageText>Subscription not found.</MessageText><ResponseCode>ErrorSubscriptionNotFound</ResponseCode>
        </GetStreamingEventsResponseMessage></ResponseMessages></GetStreamingEventsResponse></Body></Envelope>
        """
        #expect(EWSResponse.streamingChunk(from: Data(xml.utf8)).subscriptionIsGone)
    }

    @Test func requestsAreWellFormedAndCapped() throws {
        _ = try XMLTree.parse(SOAP.envelope(.exchange2010SP2, body: SOAP.subscribeToInbox))
        let body = SOAP.getStreamingEvents(subscription: "a&b", minutes: 90)
        #expect(body.contains("<m:ConnectionTimeout>30</m:ConnectionTimeout>"))
        #expect(body.contains("a&amp;b"))
    }
}

@MainActor
@Suite struct StreamerTests {
    /// The whole path: subscribe, stream, an arrival pushed by the server, and a refresh that
    /// shows it, with no poll in between.
    @Test func aStreamedArrivalReachesTheInboxWithoutAPoll() async throws {
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts,
                              client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0.3)))
        await store.refresh()
        let before = store.unreadCount(for: MockMode.accounts[0].id)

        var refreshes = 0
        let streamer = MailStreamer(store: store, onChange: {
            refreshes += 1
            Task { await store.refresh() }
        })
        streamer.sync()
        defer { streamer.stopLoops() }

        for _ in 0..<40 where store.state(for: MockMode.accounts[0].id).messages.first?.subject != MockFixtures.arrival.subject {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(refreshes >= 1)
        #expect(streamer.coversAllAccounts)
        #expect(store.state(for: MockMode.accounts[0].id).messages.first?.subject == MockFixtures.arrival.subject)
        #expect(store.unreadCount(for: MockMode.accounts[0].id) == before + 1)
    }

    @Test func aRejectedPasswordStopsStreamingInsteadOfRetrying() async throws {
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .rejected)))
        let streamer = MailStreamer(store: store, onChange: {})
        streamer.sync()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!streamer.coversAllAccounts)
        // Parked: another sync does not start a new attempt against the lockout counter.
        streamer.sync()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!streamer.coversAllAccounts)
    }
}
