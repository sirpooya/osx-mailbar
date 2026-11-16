import Foundation
import Testing
@testable import Mailbar

/// 2026-11-16: automatic replies, password expiry, mailbox quota, the activity log, Focus filters.
@Suite struct AccountHealthTests {

    private func envelope(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\(body)</s:Body></s:Envelope>
        """.utf8)
    }

    // MARK: Automatic replies

    @Test func readsAutoReplies() throws {
        let data = envelope("""
            <GetUserOofSettingsResponse xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
              <ResponseMessage ResponseClass="Success"><ResponseCode>NoError</ResponseCode></ResponseMessage>
              <OofSettings xmlns="http://schemas.microsoft.com/exchange/services/2006/types">
                <OofState>Scheduled</OofState><ExternalAudience>Known</ExternalAudience>
                <Duration><StartTime>2026-11-20T08:00:00Z</StartTime><EndTime>2026-11-27T17:00:00Z</EndTime></Duration>
                <InternalReply><Message>&lt;div&gt;Away&lt;/div&gt;</Message></InternalReply>
                <ExternalReply><Message/></ExternalReply>
              </OofSettings>
            </GetUserOofSettingsResponse>
            """)
        let settings = try EWSResponse.autoReplies(from: data)
        #expect(settings.state == .scheduled)
        #expect(settings.audience == .known)
        #expect(settings.internalHTML == "<div>Away</div>")
        #expect(settings.externalHTML == "")
        #expect(settings.start == EWSResponse.parseDate("2026-11-20T08:00:00Z"))
        #expect(!settings.isActive(at: EWSResponse.parseDate("2026-11-19T08:00:00Z")!))
        #expect(settings.isActive(at: EWSResponse.parseDate("2026-11-21T08:00:00Z")!))
        #expect(!settings.isActive(at: EWSResponse.parseDate("2026-11-28T08:00:00Z")!))
    }

    @Test func autoRepliesErrorIsThrown() {
        let data = envelope("""
            <GetUserOofSettingsResponse xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
              <ResponseMessage ResponseClass="Error"><MessageText>Access is denied.</MessageText><ResponseCode>ErrorAccessDenied</ResponseCode></ResponseMessage>
            </GetUserOofSettingsResponse>
            """)
        #expect(throws: EWSError.server("Access is denied. (ErrorAccessDenied)")) { try EWSResponse.autoReplies(from: data) }
    }

    @Test func setRequestCarriesEverythingEscaped() {
        var settings = AutoReplySettings()
        settings.state = .enabled
        settings.audience = .none
        settings.internalHTML = "<div>A & B</div>"
        let body = SOAP.setAutoReplies(settings, address: "me@example.com")
        #expect(body.contains("<t:Address>me@example.com</t:Address>"))
        #expect(body.contains("<t:OofState>Enabled</t:OofState>"))
        #expect(body.contains("<t:ExternalAudience>None</t:ExternalAudience>"))
        #expect(body.contains("<t:Message>&lt;div&gt;A &amp; B&lt;/div&gt;</t:Message>"))
        #expect(body.contains("<t:Duration><t:StartTime>"))
    }

    @Test func mockRoundTripsWhatWasSet() throws {
        var settings = AutoReplySettings()
        settings.state = .disabled
        settings.audience = .all
        settings.internalHTML = "<div>Back soon</div>"
        let mock = MockAccountHealth()
        let request = String(decoding: SOAP.envelope(.exchange2010SP2, body: SOAP.setAutoReplies(settings, address: "a@example.com")), as: UTF8.self)
        _ = mock.answer(request, isTeam: true)
        let reply = try #require(mock.answer("<m:GetUserOofSettingsRequest>", isTeam: true))
        let read = try EWSResponse.autoReplies(from: Data(reply.utf8))
        #expect(read.state == .disabled)
        #expect(read.audience == .all)
        #expect(read.internalHTML == "<div>Back soon</div>")
    }

    @Test func messagesBecomePlainTextAndBack() {
        let html = #"<html><head><style>p{}</style></head><body><div>Hello &amp; welcome</div><div><br></div><div dir="rtl">سلام&nbsp;دوست</div></body></html>"#
        #expect(AutoReplyText.plainText(fromHTML: html) == "Hello & welcome\n\nسلام دوست")
        #expect(AutoReplyText.plainText(fromHTML: "Line one\nLine two") == "Line one\nLine two")
        #expect(AutoReplyText.plainText(fromHTML: "a&#1587;&#x0644;") == "aسل")
        let back = AutoReplyText.html(fromPlainText: "Away\nتا دوشنبه")
        #expect(back.contains("<div>Away</div>"))
        #expect(back.contains(#"<div dir="rtl" style="text-align:right">تا دوشنبه</div>"#))
        #expect(AutoReplyText.html(fromPlainText: "  \n") == "")
    }

    // MARK: Password

    @Test func readsPasswordExpiryWithoutZone() throws {
        let data = envelope("""
            <GetPasswordExpirationDateResponse ResponseClass="Success" xmlns="http://schemas.microsoft.com/exchange/services/2006/messages">
              <ResponseCode>NoError</ResponseCode><PasswordExpirationDate>2026-11-21T09:19:28</PasswordExpirationDate>
            </GetPasswordExpirationDateResponse>
            """)
        #expect(try EWSResponse.passwordExpiration(from: data) == EWSResponse.parseDate("2026-11-21T09:19:28Z"))
        let none = envelope(#"<GetPasswordExpirationDateResponse ResponseClass="Success"><ResponseCode>NoError</ResponseCode></GetPasswordExpirationDateResponse>"#)
        #expect(try EWSResponse.passwordExpiration(from: none) == nil)
    }

    @MainActor @Test func expiryWarningOnlyInsideFourteenDays() {
        let now = Date()
        let day: TimeInterval = 86_400
        #expect(AccountHealth.expiryText(now.addingTimeInterval(5 * day), account: "Work", now: now)
                == "Your password for Work expires in 5 days.")
        #expect(AccountHealth.expiryText(now.addingTimeInterval(20 * day), account: "Work", now: now) == nil)
        #expect(AccountHealth.expiryText(now.addingTimeInterval(-day), account: "Work", now: now) == nil)
        #expect(AccountHealth.expiryText(now.addingTimeInterval(14 * day), account: "Work", now: now) != nil)
    }

    // MARK: Quota

    @Test func quotaFromRootAndFolders() throws {
        let reply = try #require(MockAccountHealth().answer(
            #"<m:GetFolder><t:DistinguishedFolderId Id="msgfolderroot"/><t:ExtendedFieldURI PropertyTag="0x0E08""#, isTeam: false))
        let quota = try #require(try EWSResponse.mailboxQuota(from: Data(reply.utf8)))
        #expect(quota.limit == Int64(2) << 30)
        #expect(quota.isAlmostFull)
        #expect(quota.summary.hasSuffix("of 2 GB"))
    }

    @Test func quotaWithoutLimitsSumsFolders() throws {
        let reply = try #require(MockAccountHealth().answer(
            #"<m:GetFolder><t:DistinguishedFolderId Id="msgfolderroot"/><t:ExtendedFieldURI PropertyTag="0x0E08""#, isTeam: true))
        let quota = try #require(try EWSResponse.mailboxQuota(from: Data(reply.utf8)))
        #expect(quota.limit == nil)
        #expect(!quota.isAlmostFull)
        // Folders 1 to 8 of 9 (the last is missing), 21 MB times its position.
        #expect(quota.used == Int64((1...8).reduce(0, +)) * 21 * (1 << 20))
        #expect(!quota.summary.contains("of"))
    }

    // MARK: Activity log

    @Test func logEntryNamesOperationAndHidesAddresses() throws {
        let body = SOAP.envelope(.exchange2010SP2, body: SOAP.getAutoReplies(address: "me@example.com"))
        #expect(ActivityLog.operation(in: body) == "GetUserOofSettings")
        #expect(ActivityLog.operation(in: SOAP.envelope(.exchange2010SP2, body: SOAP.getInbox)) == "GetFolder")
        let url = URL(string: "https://mail.example.com/EWS/Exchange.asmx")!
        let entry = try #require(ActivityLog.entry(for: EWSError.server("No mailbox for jane.doe@example.com."),
                                                   operation: nil, body: body, url: url, username: "me", at: Date()))
        #expect(entry.operation == "GetUserOofSettings")
        #expect(entry.host == "mail.example.com")
        #expect(entry.message == "No mailbox for (address)")
        #expect(ActivityLog.entry(for: CancellationError(), operation: nil, body: body, url: url, username: "me", at: Date()) == nil)
    }

    @Test func failedReplyIsDetectedOnlyWhenNothingSucceeded() {
        let allFailed = envelope(#"<m:R xmlns:m="urn:x"><m:ResponseMessages><m:X ResponseClass="Error"><m:MessageText>Busy</m:MessageText><m:ResponseCode>ErrorServerBusy</m:ResponseCode></m:X></m:ResponseMessages></m:R>"#)
        #expect(ActivityLog.responseError(in: allFailed) != nil)
        let partly = envelope(#"<m:R xmlns:m="urn:x"><m:ResponseMessages><m:X ResponseClass="Success"/><m:X ResponseClass="Error"/></m:ResponseMessages></m:R>"#)
        #expect(ActivityLog.responseError(in: partly) == nil)
    }

    @MainActor @Test func logKeepsHundredPerAccount() {
        let log = ActivityLog()
        let work = MockMode.accounts[0]
        let team = MockMode.accounts[1]
        log.clear(work)
        log.clear(team)
        for index in 0..<120 {
            log.record(ActivityEntry(time: Date(), operation: "FindItem \(index)", host: "h", message: "m",
                                     accountKey: ActivityLog.key(for: work)))
        }
        log.record(ActivityEntry(time: Date(), operation: "Subscribe", host: "h", message: "m",
                                 accountKey: ActivityLog.key(for: team)))
        #expect(log.entries(for: work).count == ActivityLog.limit)
        #expect(log.entries(for: work).first?.operation == "FindItem 119")
        #expect(log.entries(for: team).count == 1)
        log.clear(work)
        #expect(log.entries(for: work).isEmpty)
        #expect(log.entries(for: team).count == 1)
    }

    // MARK: Focus filter

    @MainActor @Test func focusFilterSilencesOtherAccounts() {
        let state = FocusFilterState()
        let a = UUID(), b = UUID()
        #expect(state.allows(a))
        state.keptAccounts = [a]
        #expect(state.allows(a))
        #expect(!state.allows(b))
        #expect(state.filter([a: 3, b: 4]) == [a: 3])
        #expect(FocusFilterState.kept(from: []) == nil)
        #expect(FocusFilterState.kept(from: nil) == nil)
    }
}
