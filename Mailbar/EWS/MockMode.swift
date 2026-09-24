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

/// A pretend Exchange server with a memory. Reads, flags, deletes and archives stick across
/// polls for the life of the process, so every action can be exercised end to end without a
/// mailbox. The second account starts with no Archive folder, to exercise the "create one?" ask.
final class MockTransport: EWSTransport, @unchecked Sendable {
    let mode: MockMode

    private let lock = NSLock()
    private var removed: Set<String> = []
    private var readOverrides: [String: Bool] = [:]
    private var flagOverrides: [String: Bool] = [:]
    private var teamHasArchive = false

    init(mode: MockMode) {
        self.mode = mode
    }

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

        let isTeam = url.host?.hasSuffix("example.org") == true
        let prefix = isTeam ? "team" : "work"
        let itemID = Self.firstMatch(#"ItemId Id="([^"]+)""#, in: request)

        // Autodiscover for the invented domains only; anything else does not resolve.
        if request.contains("<Autodiscover") {
            guard url.host == "autodiscover.example.com" else { throw URLError(.cannotFindHost) }
            guard credential.username == "sample.user" else { return (Data(), 401) }
            return ok(MockFixtures.autodiscover)
        }

        return lock.withLock {
            if request.contains("<m:GetFolder>") {
                return ok(MockFixtures.getFolder(unread: mode == .empty ? 0 : inbox(prefix).filter { !$0.isRead }.count))
            }
            if request.contains("<m:FindItem") {
                return ok(MockFixtures.findItem(mode == .empty ? [] : inbox(prefix)))
            }
            if request.contains("<m:GetItem>"), let itemID,
               let message = inbox(prefix).first(where: { $0.id == itemID }) {
                return ok(MockFixtures.getItem(message))
            }
            if request.contains("<m:GetAttachment>") {
                return ok(MockFixtures.attachment)
            }
            if request.contains("<m:UpdateItem"), let itemID {
                if let read = Self.firstMatch("<t:IsRead>(true|false)</t:IsRead>", in: request) {
                    readOverrides[itemID] = read == "true"
                }
                if let flag = Self.firstMatch("<t:FlagStatus>(\\w+)</t:FlagStatus>", in: request) {
                    flagOverrides[itemID] = flag == "Flagged"
                }
                return ok(MockFixtures.success("UpdateItem"))
            }
            if request.contains("<m:DeleteItem"), let itemID {
                removed.insert(itemID)
                return ok(MockFixtures.success("DeleteItem"))
            }
            if request.contains("<m:FindFolder") {
                let has = !isTeam || teamHasArchive
                return ok(MockFixtures.findFolder(found: has ? "\(prefix)-archive" : nil))
            }
            if request.contains("<m:CreateFolder>") {
                teamHasArchive = true
                return ok(MockFixtures.createFolder(id: "\(prefix)-archive"))
            }
            if request.contains("<m:MoveItem>"), let itemID {
                removed.insert(itemID)
                return ok(MockFixtures.success("MoveItem"))
            }
            return (Data(MockFixtures.fault.utf8), 500)
        }
    }

    /// The fixture inbox with every change made so far applied. Call with the lock held.
    private func inbox(_ prefix: String) -> [MockFixtures.Message] {
        let base = prefix == "team" ? MockFixtures.teamInbox : MockFixtures.workInbox
        return base.enumerated().compactMap { index, message in
            var message = message
            message.id = "\(prefix)-\(index)"
            guard !removed.contains(message.id) else { return nil }
            if let read = readOverrides[message.id] { message.isRead = read }
            if let flag = flagOverrides[message.id] { message.isFlagged = flag }
            return message
        }
    }

    private func ok(_ xml: String) -> (Data, Int) { (Data(xml.utf8), 200) }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

enum MockFixtures {
    struct Message {
        var id = ""
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
                        <t:ItemId Id="\(message.id.isEmpty ? "item-\(index)" : message.id)" ChangeKey="ck-\(index)"/>
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

    /// The body a mock message opens to: its preview as the first paragraph, a second paragraph,
    /// an inline image by `cid:` and a remote 1x1 tracking pixel, so the reader shows both the
    /// inlined image and the "remote images are blocked" line.
    static func getItem(_ message: Message, now: Date = Date()) -> String {
        let received = ISO8601DateFormatter().string(from: now.addingTimeInterval(-message.hoursAgo * 3600))
        let rtl = TextDirection.firstStrong(in: message.preview) == .rightToLeft
        let html = """
        <html><head><style>p { margin: 0 0 10px; }</style></head>
        <body dir="\(rtl ? "rtl" : "ltr")">
        \(message.sender == "Newsletter" ? MockFixtures.wideNewsletter : "")
        \(message.hasAttachments ? #"<p><img src="cid:photo@mock" alt="photo"></p>"# : "")
        <p>\(message.preview)</p>
        <p>\(rtl ? "با سپاس،" : "Thanks,")<br>\(message.sender)</p>
        <p><img src="cid:logo@mock" alt="logo" width="120" height="24"></p>
        <img src="\(pixelURL)?id=\(message.id)" width="1" height="1">
        </body></html>
        """
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>
                <m:GetItemResponseMessage ResponseClass="Success">
                  <m:ResponseCode>NoError</m:ResponseCode>
                  <m:Items>
                    <t:Message>
                      <t:ItemId Id="\(message.id)" ChangeKey="ck"/>
                      <t:Subject>\(SOAP.escape(message.subject))</t:Subject>
                      <t:Body BodyType="HTML">\(SOAP.escape(html))</t:Body>
                      <t:Attachments>
                        <t:FileAttachment>
                          <t:AttachmentId Id="att-logo"/>
                          <t:Name>logo.png</t:Name>
                          <t:ContentType>image/png</t:ContentType>
                          <t:ContentId>logo@mock</t:ContentId>
                          <t:IsInline>true</t:IsInline>
                        </t:FileAttachment>
                        <t:FileAttachment>
                          <t:AttachmentId Id="att-photo"/>
                          <t:Name>photo.png</t:Name>
                          <t:ContentType>image/png</t:ContentType>
                          <t:ContentId>photo@mock</t:ContentId>
                          <t:IsInline>true</t:IsInline>
                        </t:FileAttachment>
                      </t:Attachments>
                      <t:DateTimeReceived>\(received)</t:DateTimeReceived>
                      <t:ToRecipients><t:Mailbox><t:Name>Sample User</t:Name><t:EmailAddress>sample.user@example.com</t:EmailAddress></t:Mailbox></t:ToRecipients>
                      <t:From><t:Mailbox><t:Name>\(SOAP.escape(message.sender))</t:Name><t:EmailAddress>\(message.address)</t:EmailAddress></t:Mailbox></t:From>
                    </t:Message>
                  </m:Items>
                </m:GetItemResponseMessage>
              </m:ResponseMessages>
            </m:GetItemResponse>
          </s:Body>
        </s:Envelope>
        """
    }

    /// Where the mock tracking pixel points. `MAILBAR_MOCK_PIXEL=http://127.0.0.1:8765/open.gif`
    /// aims it at a local server, which is how the block is proven: that server must log nothing
    /// until "Load images" is pressed.
    static var pixelURL: String {
        ProcessInfo.processInfo.environment["MAILBAR_MOCK_PIXEL"] ?? "https://tracker.example.net/open.gif"
    }

    /// A fixed 600px table with a 600x150 image slot, the shape real newsletters have, to check the
    /// reader zooms it to fit without changing any proportions.
    static let wideNewsletter = """
    <table width="600" cellpadding="0" cellspacing="0" style="background:#b8dcea"><tr><td align="center">
    <img src="cid:logo@mock" width="600" height="120" alt="banner">
    <p style="font-size:22px;margin:16px">A 600 pixel wide newsletter layout</p>
    </td></tr></table>
    """

    /// A 1600x800 photo-sized image in the mail that has attachments, to check the reader fits a
    /// large image to the text column, proportionally, with no sideways scroll.
    static let photoPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAABkAAAAMgCAIAAAD0ojkNAABFrklEQVR42u3YQQ3AIBREQYTVEU7wUz/1gAEskGwPe5jkKSDDP+zY79Rl33p0GS1cccUVV1xxJa644oorrrgSV381cAHLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK3HFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxxRUwXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccUVV8BwxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFldcAcMVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFjEgOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK66A4YorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664Ei0GLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcGLGLAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKtHDFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXHElrrjiyoAFloMlrrjiiiuuuBJXXHHFFVdciSsDFlgOFldciSuuuOKKK67EFVdcccWVAUtgOVhcccUVV6KFK6644oorrsQVVwYssBwsrsQVV1xxxRVX4oorrrjiiisZsMBysLjiiitxxRVXXHHFlbjiiiuuDFhgycHiiiuuuOKKK3HFFVdcccWVuDJggeVgccWVuOKKK6644kpcccUVV1wZsASWg8UVV1xxJa644oorrrgSV1xxZcACy8ESLVxxxRVXXHElrrjiiiuuuJIBCywHiyuuuBJXXHHFFVdciSuuuOLKgAWWHCyuuOKKK67EFVdcccUVV+KKKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiitxxRVXBiywHCxxxRVXXHHFlbjiiiuuuOKKK2AMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuBJXXHHFFVdciSuuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVX4oorrrjiiiuugOGKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHElAxZYDhZXXHElrrjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorA5bAcrC44oorrrgChiuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxZW44oorrgxYYMnB4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK664EldccWXAAsvB4goYrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdcccUVMAYssBwsrrjiSlxxxRVXXHElrrjiiisDFlhysLjiiiuuuBJXXHHFFVdciSuuDFhgOVhciSuuuOKKK67EFVdcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFFVfAcMUVV1wZsMCSg8UVV1xxxZW44oorrrjiSlxxZcACy8HiSlxxxRVXXHElrrjiiiuuuJIBCywHiyuuuBJXXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJq3DA8gQ+oU/IFVdccSWuuOKKK664EldccdWcAQssB4srrrjiSlxxxRVXXHElrrjiyoAFloMlrrjiiiuuuBJXXHHFFVdciSsDFlgOFldciSuuuOKKK67EFVdcccWVAQssYhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kq0cMUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBJXXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXooUrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WuOKKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuBItXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK3HFFVdcccWVuOKKK6644sqAhQtYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK66A4YorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuuAKGK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLjiChiuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxZcAiBiwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccUVV8BwxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVdcAcMVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbhKByxP4BP6hFxxxRVX4oorrrjiiitxxRVXzRmwwHKwuOKKK67EFVdcccUVV+KKK64MWGA5WOKKK6644oorccUVV1xxxZW4MmCB5WBxxZW44oorrrjiSlxxxRVXXBmwwCLGweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuRAtXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oorccUVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdccSVauOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkrrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4sr0cIVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFi4gOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaD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iiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbhKByxP4BP6hFxxxRVX4oorrrjiiitxxRVXzRmwwHKwuOKKK67EFVdcccUVV+KKK64MWGA5WOKKK6644oorccUVV1xxxZW4MmCB5WBxxZW44oorrrjiSlxxxRVXXBmwwCLGweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuRAtXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oorccUVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdccSVauOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkrrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4sr0cIVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFi4gOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK66A4YorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcGLGLAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXHEFDFdccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxxRUwXHHFFVdccSWuDFhgOVhccSWuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVXXIkrrrjiiiuuZMACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8UVV8BwxRVXXHHFlbjiiiuuuDJgCSwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJFgMWWA4WV1xxJa644oorrrgSV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKwMWMWA5WFxxxRVX4oorrrjiiitxxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSVauOKKK64MWGDJweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuuBJXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oor0cIVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdcccWVuOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkWrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdcccUVMAYssBwsrrjiSlxxxRVXXHElrrjiiisDFlhysLjiiiuuuBJXXHHFFVdciSuuDFhgOVhciSuuuOKKK67EFVdcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFFVfAcMUVV1wZsMCSg8UVV1xxxZW44oorrrjiSlxxZcACy8HiSlxxxRVXXHElrrjiiiuuuJIBCywHiyuuuBJXXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJq3TA8gQ+oU/IFVdccSWuuOKKK664EldccdWcAQssB4srrrjiSlxxxRVXXHElrrjiyoAFloMlrrjiiiuuuBJXXHHFFVdciSsDFlgOFldciSuuuOKKK67EFVdcccWVAQssYhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kq0cMUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBJXXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXooUrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WuOKKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuBItXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK3HFFVdcccWVuOKKK6644sqAhQtYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK66A4YorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuuAKGK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLjiChiuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxZcAiBiwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccUVV8BwxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVdcAcMVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbhKByxP4BP6hFxxxRVX4oorrrjiiitxxRVXzRmwwHKwuOKKK67EFVdcccUVV+KKK64MWGA5WOKKK6644oorccUVV1xxxZW4MmCB5WBxxZW44oorrrjiSlxxxRVXXBmwwCLGweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuRAtXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oorccUVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdccSVauOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkrrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4sr0cIVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFi4gOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK66A4YorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKK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uOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK66A4YorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuuAKGK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLjiChiuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxZcAiBiwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccUVV8BwxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVdcAcMVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgKOxRexWU5PAq8AAAAAElFTkSuQmCC"

    static let logoPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAHgAAAAYCAIAAAC+8q7fAAAAW0lEQVR42u3ZMREAEACFYU1E0EcJLQQRSgmbBBpwFoP77v75Dd/6QixdDwoIQP8Fneo4lts8ZmcfaNCgQYMGDRoQaNCgQYMGDQg0aNCgQYMGBPonaCeTzxC07ltJ8elfIzIdLgAAAABJRU5ErkJggg=="

    static let attachment = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <m:GetAttachmentResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
    xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
          <m:ResponseMessages>
            <m:GetAttachmentResponseMessage ResponseClass="Success">
              <m:ResponseCode>NoError</m:ResponseCode>
              <m:Attachments>
                <t:FileAttachment>
                  <t:AttachmentId Id="att-logo"/>
                  <t:Name>logo.png</t:Name>
                  <t:ContentType>image/png</t:ContentType>
                  <t:ContentId>logo@mock</t:ContentId>
                  <t:Content>\(logoPNGBase64)</t:Content>
                </t:FileAttachment>
                <t:FileAttachment>
                  <t:AttachmentId Id="att-photo"/>
                  <t:Name>photo.png</t:Name>
                  <t:ContentType>image/png</t:ContentType>
                  <t:ContentId>photo@mock</t:ContentId>
                  <t:Content>\(photoPNGBase64)</t:Content>
                </t:FileAttachment>
              </m:Attachments>
            </m:GetAttachmentResponseMessage>
          </m:ResponseMessages>
        </m:GetAttachmentResponse>
      </s:Body>
    </s:Envelope>
    """

    static func success(_ operation: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <m:\(operation)Response xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
              <m:ResponseMessages>
                <m:\(operation)ResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode></m:\(operation)ResponseMessage>
              </m:ResponseMessages>
            </m:\(operation)Response>
          </s:Body>
        </s:Envelope>
        """
    }

    static func findFolder(found id: String?) -> String {
        let folders = id.map { #"<t:Folder><t:FolderId Id="\#($0)" ChangeKey="f"/><t:DisplayName>Archive</t:DisplayName></t:Folder>"# } ?? ""
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <m:FindFolderResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>
                <m:FindFolderResponseMessage ResponseClass="Success">
                  <m:ResponseCode>NoError</m:ResponseCode>
                  <m:RootFolder TotalItemsInView="\(id == nil ? 0 : 1)" IncludesLastItemInRange="true">
                    <t:Folders>\(folders)</t:Folders>
                  </m:RootFolder>
                </m:FindFolderResponseMessage>
              </m:ResponseMessages>
            </m:FindFolderResponse>
          </s:Body>
        </s:Envelope>
        """
    }

    static func createFolder(id: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <m:CreateFolderResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
              <m:ResponseMessages>
                <m:CreateFolderResponseMessage ResponseClass="Success">
                  <m:ResponseCode>NoError</m:ResponseCode>
                  <m:Folders><t:Folder><t:FolderId Id="\(id)" ChangeKey="f"/></t:Folder></m:Folders>
                </m:CreateFolderResponseMessage>
              </m:ResponseMessages>
            </m:CreateFolderResponse>
          </s:Body>
        </s:Envelope>
        """
    }

    static let autodiscover = """
    <?xml version="1.0" encoding="utf-8"?>
    <Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">
      <Response xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a">
        <User>
          <DisplayName>Sample User</DisplayName>
          <EMailAddress>sample.user@example.com</EMailAddress>
        </User>
        <Account>
          <AccountType>email</AccountType>
          <Action>settings</Action>
          <Protocol>
            <Type>EXCH</Type>
            <Server>internal.example.com</Server>
            <EwsUrl>https://internal.example.com/EWS/Exchange.asmx</EwsUrl>
          </Protocol>
          <Protocol>
            <Type>EXPR</Type>
            <Server>mail.example.com</Server>
            <EwsUrl>https://mail.example.com/EWS/Exchange.asmx</EwsUrl>
          </Protocol>
        </Account>
      </Response>
    </Autodiscover>
    """

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
