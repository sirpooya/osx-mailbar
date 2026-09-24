import Foundation
import Testing
@testable import Mailbar

/// Answers every request with one fixed status and body, and records what was sent.
private final class StubTransport: EWSTransport, @unchecked Sendable {
    let status: Int
    let body: String
    var error: Error?
    private(set) var lastBody = ""

    init(status: Int = 200, body: String = "", error: Error? = nil) {
        self.status = status
        self.body = body
        self.error = error
    }

    func send(_ body: Data, to url: URL, credential: EWSCredential) async throws -> (Data, Int) {
        lastBody = String(decoding: body, as: UTF8.self)
        if let error { throw error }
        return (Data(self.body.utf8), status)
    }
}

private let endpoint = URL(string: "https://mail.example.com/EWS/Exchange.asmx")!
private let credential = EWSCredential(username: "someone", password: "not-a-real-password")

@Suite struct EndpointTests {
    @Test func bareHostGetsTheStandardEWSPath() {
        #expect(Account.normalizedEndpoint("mail.example.com")?.absoluteString
                == "https://mail.example.com/EWS/Exchange.asmx")
    }

    @Test func ewsFolderAloneGetsTheFileName() {
        #expect(Account.normalizedEndpoint("https://mail.example.com/ews/")?.absoluteString
                == "https://mail.example.com/EWS/Exchange.asmx")
    }

    @Test func fullURLIsKeptAsTyped() {
        #expect(Account.normalizedEndpoint(" https://mail.example.com/ews/exchange.asmx ")?.absoluteString
                == "https://mail.example.com/ews/exchange.asmx")
    }

    @Test func plainHTTPIsRefusedBecauseItCarriesThePassword() {
        #expect(Account.normalizedEndpoint("http://mail.example.com/EWS/Exchange.asmx") == nil)
    }

    @Test func emptyIsNil() {
        #expect(Account.normalizedEndpoint("  ") == nil)
    }
}

@Suite struct SOAPTests {
    @Test func escapesEveryMarkupCharacter() {
        #expect(SOAP.escape(#"a<b>&"c'"#) == "a&lt;b&gt;&amp;&quot;c&apos;")
    }

    @Test func modernFindAsksForPreviewAndFlag() {
        let body = SOAP.findInbox(limit: 50, modern: true)
        #expect(body.contains("item:Preview"))
        #expect(body.contains("item:Flag"))
        #expect(!body.contains("0x1090"))
        #expect(body.contains(#"MaxEntriesReturned="50""#))
    }

    @Test func legacyFindUsesTheMAPIFlagInstead() {
        let body = SOAP.findInbox(limit: 50, modern: false)
        #expect(!body.contains("item:Preview"))
        #expect(!body.contains("item:Flag"))
        #expect(body.contains("0x1090"))
    }

    @Test func envelopeIsWellFormedXML() throws {
        let data = SOAP.envelope(.exchange2013, body: SOAP.findInbox(limit: 10, modern: true))
        let root = try XMLTree.parse(data)
        #expect(root.name == "Envelope")
        #expect(root.first("RequestServerVersion")?.attributes["Version"] == "Exchange2013")
        #expect(root.first("FindItem") != nil)
    }
}

@Suite struct ResponseParsingTests {
    @Test func readsUnreadCountAndServerVersion() throws {
        let status = try EWSResponse.inboxStatus(from: Data(MockFixtures.getFolder(unread: 7).utf8))
        #expect(status.unreadCount == 7)
        #expect(status.totalCount == 1840)
        #expect(status.version == ServerVersion(major: 15, minor: 1))
        #expect(status.version?.isModern == true)
    }

    @Test func readsEveryRowField() throws {
        let now = Date()
        let xml = MockFixtures.findItem(MockFixtures.workInbox, now: now)
        let messages = try EWSResponse.messages(from: Data(xml.utf8))
        #expect(messages.count == MockFixtures.workInbox.count)

        let first = try #require(messages.first)
        #expect(first.id == "item-0")
        #expect(first.changeKey == "ck-0")
        #expect(first.senderName == "People Operations")
        #expect(first.senderAddress == "people@example.com")
        #expect(first.subject.hasPrefix("یادآوری"))
        #expect(!first.preview.isEmpty)
        #expect(first.isRead == false)
        #expect(abs(first.received.timeIntervalSince(now.addingTimeInterval(-1.5 * 3600))) < 2)

        let flagged = try #require(messages.first { $0.senderName == "Sara Rahimi" })
        #expect(flagged.isFlagged)
        #expect(flagged.hasAttachments)
        #expect(!messages[1].isFlagged)
    }

    @Test func emptyInboxIsAnEmptyListNotAnError() throws {
        let messages = try EWSResponse.messages(from: Data(MockFixtures.findItem([]).utf8))
        #expect(messages.isEmpty)
    }

    @Test func legacyFlagComesFromTheMAPIProperty() throws {
        let item = try XMLTree.parse(Data("""
        <Message><ItemId Id="x" ChangeKey="y"/>
          <ExtendedProperty><ExtendedFieldURI PropertyTag="0x1090" PropertyType="Integer"/><Value>2</Value></ExtendedProperty>
        </Message>
        """.utf8))
        #expect(EWSResponse.message(from: item)?.isFlagged == true)
    }

    @Test func missingSenderAndSubjectGetReadableStandIns() throws {
        let item = try XMLTree.parse(Data(#"<Message><ItemId Id="x" ChangeKey="y"/></Message>"#.utf8))
        let message = try #require(EWSResponse.message(from: item))
        #expect(message.senderName == "No sender")
        #expect(message.subject == "(No subject)")
    }

    @Test func previewIsOneLine() {
        #expect(EWSResponse.previewText("Hello,\r\n\r\n  second   line\tend") == "Hello, second line end")
    }

    @Test func errorResponseClassThrowsWithTheServersWords() {
        let xml = """
        <Envelope><Body><GetFolderResponse><ResponseMessages>
          <GetFolderResponseMessage ResponseClass="Error">
            <MessageText>The specified folder could not be found.</MessageText>
            <ResponseCode>ErrorFolderNotFound</ResponseCode>
          </GetFolderResponseMessage>
        </ResponseMessages></GetFolderResponse></Body></Envelope>
        """
        #expect(throws: EWSError.server("The specified folder could not be found. (ErrorFolderNotFound)")) {
            try EWSResponse.inboxStatus(from: Data(xml.utf8))
        }
    }
}

@Suite struct ClientStatusMappingTests {
    @Test func unauthorizedIsPasswordRejected() async {
        let client = EWSClient(transport: StubTransport(status: 401))
        await #expect(throws: EWSError.passwordRejected) {
            try await client.inboxStatus(at: endpoint, credential: credential)
        }
    }

    @Test func cancelledChallengeIsPasswordRejected() async {
        let client = EWSClient(transport: StubTransport(error: URLError(.userCancelledAuthentication)))
        await #expect(throws: EWSError.passwordRejected) {
            try await client.inboxStatus(at: endpoint, credential: credential)
        }
    }

    @Test func dnsFailureIsUnreachable() async {
        let client = EWSClient(transport: StubTransport(error: URLError(.cannotFindHost)))
        await #expect(throws: EWSError.unreachable("The server name does not resolve.")) {
            try await client.inboxStatus(at: endpoint, credential: credential)
        }
    }

    @Test func badCertificateIsATLSFailureNotUnreachable() async {
        let client = EWSClient(transport: StubTransport(error: URLError(.serverCertificateUntrusted)))
        await #expect(throws: EWSError.tlsFailure("The server's certificate was not accepted.")) {
            try await client.inboxStatus(at: endpoint, credential: credential)
        }
    }

    @Test func notFoundIsNotEWS() async {
        let client = EWSClient(transport: StubTransport(status: 404))
        await #expect(throws: EWSError.notEWS("Nothing answers at that path on the server (404).")) {
            try await client.inboxStatus(at: endpoint, credential: credential)
        }
    }

    @Test func soapFaultCarriesItsFaultString() async {
        let client = EWSClient(transport: StubTransport(status: 500, body: MockFixtures.fault))
        await #expect(throws: EWSError.server("The server cannot service this request right now. Try again later.")) {
            try await client.inboxStatus(at: endpoint, credential: credential)
        }
    }

    @Test func statusProbeUsesTheOldestVersionEveryServerAccepts() async throws {
        let transport = StubTransport(body: MockFixtures.getFolder(unread: 1))
        _ = try await EWSClient(transport: transport).inboxStatus(at: endpoint, credential: credential)
        #expect(transport.lastBody.contains(#"Version="Exchange2010_SP2""#))
        #expect(!transport.lastBody.contains(credential.password))
    }
}
