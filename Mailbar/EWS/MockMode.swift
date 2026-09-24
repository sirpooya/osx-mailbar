import Foundation

/// `MAILBAR_MOCK` serves canned EWS replies so every surface can be exercised without an account.
///
///     MAILBAR_MOCK=1 open Mailbar.app            two invented accounts, a full inbox
///     MAILBAR_MOCK=empty | unreachable | rejected | failed | loading
///
/// The fixtures are real response XML, so a mock run also checks that the parser still reads what
/// Exchange sends. Every name and address is invented; nothing here is anybody's real mail.
/// DEBUG only: a release build ignores the variable entirely.
enum MockMode: String, Sendable {
    case inbox = "1"
    case empty
    case unreachable
    case rejected
    case failed
    case loading

    static var current: MockMode? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["MAILBAR_MOCK"], !raw.isEmpty else { return nil }
        return MockMode(rawValue: raw) ?? .inbox
        #else
        return nil
        #endif
    }

    /// Two accounts, so the account menu and the swipe between inboxes have something to show.
    static let accounts: [Account] = [
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
                label: "Work", fullName: "Sample User", email: "sample.user@example.com",
                serverURL: "https://mail.example.com/EWS/Exchange.asmx", username: "sample.user"),
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!,
                label: "Team inbox", fullName: "Sample Team", email: "team@example.org",
                serverURL: "https://exchange.example.org/EWS/Exchange.asmx", username: "team"),
    ]

    static var passwords: MemoryPasswordStore {
        MemoryPasswordStore(Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, "mock") }))
    }
}

struct MockTransport: EWSTransport {
    let mode: MockMode

    func send(_ body: Data, to url: URL, credential: EWSCredential) async throws -> (Data, Int) {
        let request = String(decoding: body, as: UTF8.self)
        switch mode {
        case .loading:
            try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
        case .unreachable:
            try await Task.sleep(nanoseconds: 300_000_000)
            throw URLError(.cannotFindHost)
        case .rejected:
            return (Data(), 401)
        case .failed:
            return (Data(MockFixtures.fault.utf8), 500)
        case .inbox, .empty:
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let isSecondAccount = url.host?.hasSuffix("example.org") == true
        if request.contains("<m:GetFolder>") {
            let unread = mode == .empty ? 0 : (isSecondAccount ? 1 : 3)
            return (Data(MockFixtures.getFolder(unread: unread).utf8), 200)
        }
        if request.contains("<m:FindItem") {
            let messages: [MockFixtures.Message]
            switch mode {
            case .empty: messages = []
            default: messages = isSecondAccount ? MockFixtures.teamInbox : MockFixtures.workInbox
            }
            return (Data(MockFixtures.findItem(messages).utf8), 200)
        }
        return (Data(MockFixtures.fault.utf8), 500)
    }
}

enum MockFixtures {
    struct Message {
        let sender: String
        let address: String
        let subject: String
        let preview: String
        let hoursAgo: Double
        var isRead = false
        var isFlagged = false
        var hasAttachments = false
    }

    static let workInbox: [Message] = [
        Message(sender: "People Operations", address: "people@example.com",
                subject: "یادآوری: خودارزیابی نیم‌سال را هنوز ثبت نکرده‌اید | مهلت تا پایان هفته",
                preview: "همکار گرامی سلام، دورهٔ ارزیابی عملکرد نیم‌سال آغاز شده است و فرم خودارزیابی شما هنوز تکمیل نشده است.",
                hoursAgo: 1.5),
        Message(sender: "Build Server", address: "ci@example.com",
                subject: "Nightly build 2417 passed",
                preview: "All 312 tests passed in 14 minutes. No new warnings. Artifacts are attached to the run.",
                hoursAgo: 5, isRead: true),
        Message(sender: "Sara Rahimi", address: "sara.rahimi@example.com",
                subject: "Design review notes and the updated spacing tokens",
                preview: "Hi, attached are the notes from Tuesday. Two open points: the chip height on compact density, and whether the divider stays.",
                hoursAgo: 26, isFlagged: true, hasAttachments: true),
        Message(sender: "واحد فناوری اطلاعات", address: "it@example.com",
                subject: "قطعی برنامه‌ریزی‌شده سرویس ایمیل، پنجشنبه ساعت ۲۲",
                preview: "سرویس ایمیل برای به‌روزرسانی از ساعت ۲۲ تا ۲۳ در دسترس نخواهد بود. Outlook و موبایل هر دو متأثر می‌شوند.",
                hoursAgo: 50, isRead: true),
        Message(sender: "Travel Desk", address: "travel@example.com",
                subject: "Your booking is confirmed",
                preview: "Reference QX-4471. Check-in opens 24 hours before departure.",
                hoursAgo: 24 * 5, isRead: true),
        Message(sender: "Newsletter", address: "news@example.net",
                subject: "This month in product: three launches and a retrospective",
                preview: "Read the highlights, then the full write-up from each team.",
                hoursAgo: 24 * 21, isRead: true),
        Message(sender: "Finance", address: "finance@example.com",
                subject: "Year-end expense deadline",
                preview: "Please submit remaining receipts before the books close.",
                hoursAgo: 24 * 380, isRead: true),
    ]

    static let teamInbox: [Message] = [
        Message(sender: "Support Queue", address: "support@example.org",
                subject: "New ticket: cannot sign in on the mobile app",
                preview: "Customer reports a loop on the sign-in screen after updating.",
                hoursAgo: 0.3),
        Message(sender: "Omid Karimi", address: "omid@example.org",
                subject: "Re: هماهنگی جلسهٔ هفتگی",
                preview: "سه‌شنبه ساعت ۱۰ برای من مناسب است. agenda را هم به‌روز کردم.",
                hoursAgo: 30, isRead: true),
    ]

    static func getFolder(unread: Int) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Header>
            <h:ServerVersionInfo MajorVersion="15" MinorVersion="1" MajorBuildNumber="2507" MinorBuildNumber="6" \
        xmlns:h="http://schemas.microsoft.com/exchange/services/2006/types"/>
          </s:Header>
          <s:Body>
            <m:GetFolderResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>
                <m:GetFolderResponseMessage ResponseClass="Success">
                  <m:ResponseCode>NoError</m:ResponseCode>
                  <m:Folders>
                    <t:Folder>
                      <t:FolderId Id="AAMkInbox" ChangeKey="AQAAAA=="/>
                      <t:DisplayName>Inbox</t:DisplayName>
                      <t:TotalCount>1840</t:TotalCount>
                      <t:ChildFolderCount>0</t:ChildFolderCount>
                      <t:UnreadCount>\(unread)</t:UnreadCount>
                    </t:Folder>
                  </m:Folders>
                </m:GetFolderResponseMessage>
              </m:ResponseMessages>
            </m:GetFolderResponse>
          </s:Body>
        </s:Envelope>
        """
    }

    static func findItem(_ messages: [Message], now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        let items = messages.enumerated().map { index, message in
            """
                      <t:Message>
                        <t:ItemId Id="AAMkItem\(index)" ChangeKey="CQAAAB\(index)"/>
                        <t:Subject>\(SOAP.escape(message.subject))</t:Subject>
                        <t:HasAttachments>\(message.hasAttachments)</t:HasAttachments>
                        <t:DateTimeReceived>\(formatter.string(from: now.addingTimeInterval(-message.hoursAgo * 3600)))</t:DateTimeReceived>
                        <t:Preview>\(SOAP.escape(message.preview))</t:Preview>
                        <t:From><t:Mailbox><t:Name>\(SOAP.escape(message.sender))</t:Name>\
            <t:EmailAddress>\(message.address)</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType></t:Mailbox></t:From>
                        <t:IsRead>\(message.isRead)</t:IsRead>
                        <t:Flag><t:FlagStatus>\(message.isFlagged ? "Flagged" : "NotFlagged")</t:FlagStatus></t:Flag>
                      </t:Message>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Header>
            <h:ServerVersionInfo MajorVersion="15" MinorVersion="1" \
        xmlns:h="http://schemas.microsoft.com/exchange/services/2006/types"/>
          </s:Header>
          <s:Body>
            <m:FindItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>
                <m:FindItemResponseMessage ResponseClass="Success">
                  <m:ResponseCode>NoError</m:ResponseCode>
                  <m:RootFolder IndexedPagingOffset="\(messages.count)" TotalItemsInView="\(messages.count)" IncludesLastItemInRange="true">
                    <t:Items>
        \(items)
                    </t:Items>
                  </m:RootFolder>
                </m:FindItemResponseMessage>
              </m:ResponseMessages>
            </m:FindItemResponse>
          </s:Body>
        </s:Envelope>
        """
    }

    static let fault = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <s:Fault>
          <faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:ErrorInternalServerTransientError</faultcode>
          <faultstring xml:lang="en-US">The server cannot service this request right now. Try again later.</faultstring>
        </s:Fault>
      </s:Body>
    </s:Envelope>
    """
}
