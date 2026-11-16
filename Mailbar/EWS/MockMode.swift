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
    /// Where the removed mail went, newest first, so Archive and Deleted Items list it.
    private var archived: [String] = []
    private var trashed: [String] = []
    private var readOverrides: [String: Bool] = [:]
    private var flagOverrides: [String: Bool] = [:]
    private var teamHasArchive = false
    /// Calendar changes made while the app runs (M16, M17): created events, edits by id, and the
    /// answer given to each invitation.
    private var createdEvents: [MockCalendar.Event] = []
    private var editedEvents: [String: (subject: String, start: Date, end: Date, location: String,
                                        categories: [String], charm: Int?)] = [:]
    /// Files attached in this run, and the ids removed, by event.
    private var addedFiles: [String: [(String, String, Int)]] = [:]
    private var removedFiles: Set<String> = []
    private var answers: [String: String] = [:]
    /// Replied and forwarded marks the app set (PidTagLastVerbExecuted).
    private var verbOverrides: [String: Int] = [:]
    /// Where moves of M20 and M21 put mail beyond Archive and Deleted Items: into Junk, back
    /// into the Inbox from elsewhere, and into custom folders by id. Newest first.
    private var junked: [String] = []
    private var restored: [String] = []
    private var filed: [String: [String]] = [:]

    /// The mock calendar with every change so far applied. Call with the lock held.
    private func calendarEvents() -> [MockCalendar.Event] {
        (MockCalendar.events() + createdEvents).compactMap { event in
            guard !removed.contains(event.id) else { return nil }
            var event = event
            if let edit = editedEvents[event.id] {
                event = MockCalendar.Event(id: event.id, subject: edit.subject, start: edit.start, end: edit.end,
                                           isAllDay: event.isAllDay, location: edit.location, organizer: event.organizer,
                                           organizerAddress: event.organizerAddress, isRecurring: event.isRecurring,
                                           isMeeting: event.isMeeting, isCancelled: event.isCancelled,
                                           response: event.response, showAs: event.showAs,
                                           attendees: event.attendees, notes: event.notes, categories: edit.categories,
                                           charm: edit.charm, files: event.files)
            }
            event.files = (event.files + (addedFiles[event.id] ?? [])).filter { !removed(file: $0.0) }
            if let answer = answers[event.id] { event.response = answer }
            return event
        }
    }

    private func removed(file id: String) -> Bool { removedFiles.contains(id) }

    private static func categories(in request: String) -> [String] {
        guard let block = firstMatch("<t:Categories>(.*?)</t:Categories>", in: request) else { return [] }
        return matches("<t:String>([^<]*)</t:String>", in: block).map(unescape)
    }

    private static func charm(in request: String) -> Int? {
        firstMatch(#"PropertyId="39" PropertyType="Integer"/><t:Value>(\d+)</t:Value>"#, in: request).flatMap { Int($0) }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func calendarFields(in request: String) -> (subject: String, start: Date, end: Date, location: String, allDay: Bool)? {
        guard let subject = firstMatch("<t:Subject>([^<]*)</t:Subject>", in: request),
              let start = firstMatch("<t:Start>([^<]+)</t:Start>", in: request).flatMap(EWSResponse.parseDate),
              let end = firstMatch("<t:End>([^<]+)</t:End>", in: request).flatMap(EWSResponse.parseDate) else { return nil }
        return (unescape(subject), start, end, unescape(firstMatch("<t:Location>([^<]*)</t:Location>", in: request) ?? ""),
                firstMatch("<t:IsAllDayEvent>(true|false)</t:IsAllDayEvent>", in: request) == "true")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Every send request received, for tests. Nothing is delivered anywhere.
    private(set) var sent: [String] = []

    var sentRequests: [String] { lock.withLock { sent } }

    /// The pretend Drafts and Templates folders and MailTips (M23 to M25).
    let compose = MockCompose()

    /// Messages delivered while the app runs, by account prefix. Only ever grows.
    private var arrived: [String: [MockFixtures.Message]] = [:]
    /// Seconds after a stream opens before a new message arrives on it, for the work account.
    /// `MAILBAR_MOCK_NEWMAIL=<seconds>` overrides it; 0 means never.
    let newMailAfter: TimeInterval

    init(mode: MockMode, newMailAfter: TimeInterval? = nil) {
        self.mode = mode
        let fromEnvironment = ProcessInfo.processInfo.environment["MAILBAR_MOCK_NEWMAIL"].flatMap(TimeInterval.init)
        self.newMailAfter = newMailAfter ?? fromEnvironment ?? 12
    }

    /// Streaming, with one scripted arrival: after `newMailAfter` seconds a message lands in the
    /// work inbox and a NewMailEvent envelope is written, exactly as Exchange would.
    func stream(_ body: Data, to url: URL, credential: EWSCredential) async throws
        -> (AsyncThrowingStream<Data, Error>, Int) {
        switch mode {
        case .rejected: return (AsyncThrowingStream { $0.finish() }, 401)
        case .unreachable: throw URLError(.cannotFindHost)
        case .failed, .loading, .empty, .inbox: break
        }
        let isWork = url.host?.hasSuffix("example.com") == true
        let delay = newMailAfter
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let writer = Task {
                continuation.yield(Data(MockFixtures.streamingEnvelope(event: nil).utf8))
                if isWork, delay > 0, self.lock.withLock({ (self.arrived["work"] ?? []).isEmpty }) {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.lock.withLock { self.arrived["work", default: []].append(MockFixtures.arrival) }
                    continuation.yield(Data(MockFixtures.streamingEnvelope(event: "NewMailEvent").utf8))
                }
                // Then idle, as a quiet inbox does, until the app closes the connection.
                try? await Task.sleep(nanoseconds: 1_800 * 1_000_000_000)
                continuation.yield(Data(MockFixtures.streamingEnvelope(event: nil, closed: true).utf8))
                continuation.finish()
            }
            continuation.onTermination = { _ in writer.cancel() }
        }
        return (stream, 200)
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
            // Automatic replies, password expiry, mailbox size (MockAccountHealth).
            if let reply = MockAccountHealth.shared.answer(request, isTeam: isTeam) { return ok(reply) }
            if let reply = listActionReply(request, prefix: prefix) { return reply }
            // The calendar extras: series masters, proposals, export (MockCalendarExtras).
            if let extra = MockCalendar.extraResponse(to: request, events: calendarEvents()) {
                sent.append(request)
                return ok(extra)
            }
            // Drafts, templates and MailTips (M23 to M25) first; `MockCompose` says what is its.
            if let reply = compose.answer(request, prefix: prefix) {
                sent.append(request)
                return ok(reply)
            }
            if request.contains("<m:CreateItem") {
                sent.append(request)
                if request.contains("<t:CalendarItem>"), let fields = Self.calendarFields(in: request) {
                    var event = MockCalendar.Event(id: "ev-new-\(createdEvents.count)", subject: fields.subject,
                                                   start: fields.start, end: fields.end, isAllDay: fields.allDay,
                                                   location: fields.location, organizer: "Sample User",
                                                   organizerAddress: "sample.user@example.com",
                                                   isMeeting: request.contains("<t:RequiredAttendees>"),
                                                   response: "Organizer")
                    event.isRecurring = request.contains("<t:Recurrence>")
                    event.categories = Self.categories(in: request)
                    event.charm = Self.charm(in: request)
                    event.requestsResponses = !request.contains("<t:IsResponseRequested>false</t:IsResponseRequested>")
                    event.allowsForwarding = !request.contains(#"PropertyName="DoNotForward" PropertyType="Boolean"/><t:Value>true</t:Value>"#)
                    event.requestSent = !event.isMeeting || !request.contains(#"SendMeetingInvitations="SendToNone""#)
                    createdEvents.append(event)
                    return ok(MockCalendar.createdResponse(id: event.id))
                }
                for (element, response) in [("AcceptItem", "Accept"), ("TentativelyAcceptItem", "Tentative"), ("DeclineItem", "Decline")]
                where request.contains("<t:\(element)>") {
                    if let reference = Self.firstMatch(#"ReferenceItemId Id="([^"]+)""#, in: request) {
                        // Answering the invitation email answers the event it is for.
                        let event = inbox(prefix).first { $0.id == reference }?.event
                        answers[event ?? (reference.hasPrefix("ev-") ? reference : "ev-next-planning")] = response
                    }
                }
                if request.contains("<t:RemoveItem>"),
                   let reference = Self.firstMatch(#"ReferenceItemId Id="([^"]+)""#, in: request),
                   let event = inbox(prefix).first(where: { $0.id == reference })?.event {
                    removed.insert(event)
                }
                return ok(MockFixtures.success("CreateItem"))
            }
            if request.contains("<m:ExpandDL>") {
                return ok(MockCalendar.expandResponse(Self.firstMatch("<t:EmailAddress>([^<]*)</t:EmailAddress>", in: request) ?? ""))
            }
            if request.contains("<m:ResolveNames") {
                let query = (Self.firstMatch("<m:UnresolvedEntry>([^<]*)</m:UnresolvedEntry>", in: request) ?? "").lowercased()
                return ok(MockCalendar.resolveResponse(query, full: request.contains(#"ReturnFullContactData="true""#)))
            }
            if request.contains("<m:CreateAttachment>"), let parent = Self.firstMatch(#"ParentItemId Id="([^"]+)""#, in: request) {
                sent.append(request)
                let names = Self.matches("<t:Name>([^<]*)</t:Name>", in: request).map(Self.unescape)
                let contents = Self.matches("<t:Content>([^<]*)</t:Content>", in: request)
                for (index, name) in names.enumerated() {
                    let size = Data(base64Encoded: index < contents.count ? contents[index] : "")?.count ?? 0
                    addedFiles[parent, default: []].append(("att-new-\(parent)-\(addedFiles[parent]?.count ?? 0)", name, size))
                }
                return ok(MockFixtures.success("CreateAttachment"))
            }
            if request.contains("<m:DeleteAttachment>") {
                sent.append(request)
                removedFiles.formUnion(Self.matches(#"AttachmentId Id="([^"]+)""#, in: request))
                return ok(MockFixtures.success("DeleteAttachment"))
            }
            if request.contains("<m:GetUserPhoto>") {
                return ok(MockCalendar.photoResponse(for: Self.firstMatch("<m:Email>([^<]*)</m:Email>", in: request) ?? ""))
            }
            if request.contains("<m:GetUserAvailabilityRequest>") {
                let addresses = Self.matches("<t:Address>([^<]*)</t:Address>", in: request).map(Self.unescape)
                return ok(MockCalendar.availabilityResponse(addresses, events: calendarEvents(),
                                                            detailed: request.contains("<t:RequestedView>Detailed</t:RequestedView>"),
                                                            windowStart: Self.firstMatch("<t:StartTime>([^<]*)</t:StartTime>", in: request),
                                                            windowEnd: Self.firstMatch("<t:EndTime>([^<]*)</t:EndTime>", in: request)))
            }
            if request.contains("<m:GetRoomLists") { return ok(MockCalendar.roomListsResponse) }
            if request.contains("<m:GetRooms>") { return ok(MockCalendar.roomsResponse) }
            if request.contains("<m:UpdateItem"), let itemID, itemID.hasPrefix("ev-"),
               let fields = Self.calendarFields(in: request) {
                sent.append(request)
                editedEvents[itemID] = (fields.subject, fields.start, fields.end, fields.location,
                                        Self.categories(in: request), Self.charm(in: request))
                return ok(MockFixtures.success("UpdateItem"))
            }
            if request.contains("<m:DeleteItem"), let itemID, itemID.hasPrefix("ev-") {
                sent.append(request)
                removed.insert(itemID)
                return ok(MockFixtures.success("DeleteItem"))
            }
            if request.contains("<m:GetUserConfiguration>") {
                return ok(MockCalendar.categoryListResponse)
            }
            // The calendar (M15). Checked before the inbox, since both are FindItem and GetItem.
            if request.contains("<m:CalendarView") {
                guard !isTeam else { return ok(MockCalendar.findResponse(start: .distantPast, end: .distantPast, events: [])) }
                let start = Self.firstMatch(#"StartDate="([^"]+)""#, in: request).flatMap(EWSResponse.parseDate) ?? .distantPast
                let end = Self.firstMatch(#"EndDate="([^"]+)""#, in: request).flatMap(EWSResponse.parseDate) ?? .distantFuture
                return ok(MockCalendar.findResponse(start: start, end: end, events: calendarEvents()))
            }
            if request.contains("<m:GetItem>"), let itemID, itemID.hasPrefix("ev-"),
               let event = calendarEvents().first(where: { $0.id == itemID }) {
                return ok(MockCalendar.getResponse(event))
            }
            if request.contains("<m:Subscribe>") {
                return ok(MockFixtures.subscribe)
            }
            // Search across folders, the Online Archive, calendar search (`MockSearch`).
            if let reply = MockSearch.reply(to: request, prefix: prefix, isTeam: isTeam, empty: mode == .empty, itemID: itemID,
                                            mail: { folder in
                                                // The same folders the plain FindItem below lists.
                                                switch folder {
                                                case "inbox": moved(restored, prefix) + inbox(prefix)
                                                case "sentitems": sentItems(prefix)
                                                case "deleteditems": moved(trashed, prefix)
                                                case "junkemail": moved(junked, prefix) + junk(prefix)
                                                case "\(prefix)-archive": moved(archived, prefix)
                                                case _ where folder.hasPrefix("\(prefix)-folder-"):
                                                    moved(filed[folder] ?? [], prefix) + folderNatives(folder, prefix)
                                                default: []
                                                }
                                            },
                                            events: { calendarEvents() }) {
                return ok(reply)
            }
            if request.contains("<m:GetFolder>") {
                return ok(MockFixtures.getFolder(unread: mode == .empty ? 0 : inbox(prefix).filter { !$0.isRead }.count))
            }
            if request.contains("<m:FindItem") {
                var messages: [MockFixtures.Message]
                if request.contains(#"DistinguishedFolderId Id="sentitems""#) {
                    messages = sentItems(prefix)
                } else if request.contains(#"DistinguishedFolderId Id="deleteditems""#) {
                    messages = moved(trashed, prefix)
                } else if request.contains(#"DistinguishedFolderId Id="junkemail""#) {
                    messages = moved(junked, prefix) + junk(prefix)
                } else if request.contains(#"<t:FolderId Id="\#(prefix)-archive"/>"#) {
                    messages = moved(archived, prefix)
                } else if let folder = Self.firstMatch(#"<t:FolderId Id="(\#(prefix)-folder-[^"]+)"/>"#, in: request) {
                    messages = moved(filed[folder] ?? [], prefix) + folderNatives(folder, prefix)
                } else {
                    messages = moved(restored, prefix) + inbox(prefix)
                }
                if mode == .empty { messages = [] }
                // The restrictions the app sends: Flagged (the folder or the filter), and the
                // Unread, Has Attachments and To Me filters, ANDed.
                if request.contains("<t:IsEqualTo><t:ExtendedFieldURI PropertyTag=\"0x1090\"") {
                    messages = messages.filter(\.isFlagged)
                }
                if request.contains(#"FieldURI="message:IsRead"/><t:FieldURIOrConstant><t:Constant Value="false""#) {
                    messages = messages.filter { !$0.isRead }
                }
                if request.contains(#"FieldURI="item:HasAttachments"/><t:FieldURIOrConstant>"#) {
                    messages = messages.filter(\.hasAttachments)
                }
                if request.contains(#"PropertyTag="0x0057" PropertyType="Boolean"/><t:FieldURIOrConstant>"#) {
                    messages = messages.filter(\.toMe)
                }
                // Search: the query string (2013+) or the substring restriction (older servers),
                // matched against sender, subject and preview the way Exchange's index would.
                if let query = Self.firstMatch("<m:QueryString>([^<]*)</m:QueryString>", in: request)
                    ?? Self.firstMatch(#"<t:Contains[^>]*><t:FieldURI[^>]*/><t:Constant Value="([^"]*)"/>"#, in: request) {
                    let needle = query.lowercased()
                    messages = messages.filter {
                        "\($0.sender) \($0.to ?? "") \($0.subject) \($0.preview)".lowercased().contains(needle)
                    }
                }
                // The orders the app asks for; each falls back to newest first, as the fixtures are.
                let order = Self.firstMatch("<m:SortOrder>(.*?)</m:SortOrder>", in: request.replacingOccurrences(of: "\n", with: " ")) ?? ""
                if order.contains("0x0C1A") {
                    messages.sort { $0.sender.localizedStandardCompare($1.sender) == .orderedAscending }
                } else if order.contains("0x0E04") {
                    messages.sort { ($0.to ?? "").localizedStandardCompare($1.to ?? "") == .orderedAscending }
                } else if order.contains("0x0E1D") {
                    messages.sort { MailSort.normalized($0.subject).localizedStandardCompare(MailSort.normalized($1.subject)) == .orderedAscending }
                } else if order.contains("item:Size") {
                    messages.sort { $0.size > $1.size }
                } else if order.contains("item:Importance") {
                    let rank = ["High": 2, "Normal": 1, "Low": 0]
                    messages.sort { (rank[$0.importance] ?? 1) > (rank[$1.importance] ?? 1) }
                }
                return ok(MockFixtures.findItem(messages))
            }
            // A row's files and an invitation row's time: one GetItem for many items.
            if request.contains("<m:GetItem>"), request.contains("<t:BaseShape>IdOnly</t:BaseShape>"),
               request.contains(#"FieldURI="item:Attachments"/></t:AdditionalProperties>"#) || request.contains(#"FieldURI="calendar:MyResponseType""#) {
                let all = inbox(prefix) + sentItems(prefix) + moved(archived + trashed + junked + restored + filed.values.flatMap { $0 }, prefix) + junk(prefix)
                let wanted = Self.matches(#"ItemId Id="([^"]+)""#, in: request).compactMap { id in all.first { $0.id == id } }
                if request.contains("calendar:MyResponseType") {
                    let events = calendarEvents()
                    return ok(MockFixtures.rowMeetings(wanted.compactMap { message in
                        guard let event = message.event.flatMap({ id in events.first { $0.id == id } }) else { return nil }
                        return (message, event, answers[event.id])
                    }))
                }
                return ok(MockFixtures.attachmentLists(wanted))
            }
            if request.contains("<m:GetItem>"), let itemID,
               let message = (inbox(prefix) + sentItems(prefix) + moved(archived + trashed + junked + restored + filed.values.flatMap { $0 }, prefix) + junk(prefix))
                .first(where: { $0.id == itemID }) {
                if request.contains("meeting:AssociatedCalendarItemId") {
                    let event = message.event.flatMap { id in calendarEvents().first { $0.id == id } }
                    return ok(MockFixtures.meetingLink(message, event: event?.id))
                }
                if request.contains("meetingResponse:ProposedStart") {
                    let event = message.event.flatMap { id in calendarEvents().first { $0.id == id } }
                    return ok(MockFixtures.proposedTime(message, event: event))
                }
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
                if let verb = Self.firstMatch(#"PropertyTag="0x1081" PropertyType="Integer"/><t:Value>(\d+)</t:Value>"#, in: request) {
                    sent.append(request)
                    verbOverrides[itemID] = Int(verb)
                }
                return ok(MockFixtures.success("UpdateItem"))
            }
            if request.contains("<m:DeleteItem"), let itemID {
                removed.insert(itemID)
                archived.removeAll { $0 == itemID }
                trashed.insert(itemID, at: 0)
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
                trashed.removeAll { $0 == itemID }
                archived.insert(itemID, at: 0)
                return ok(MockFixtures.success("MoveItem"))
            }
            return (Data(MockFixtures.fault.utf8), 500)
        }
    }

    /// The fixture inbox with every change made so far applied. Call with the lock held.
    private func inbox(_ prefix: String) -> [MockFixtures.Message] {
        let base = prefix == "team" ? MockFixtures.teamInbox : MockFixtures.workInbox
        let newest = (arrived[prefix] ?? []).reversed().enumerated().map { index, message in
            var message = message
            message.id = "\(prefix)-new-\(index)"
            return message
        }
        return (newest + base.enumerated().map { index, message in
            var message = message
            message.id = "\(prefix)-\(index)"
            return message
        }).compactMap { message in
            var message = message
            guard !removed.contains(message.id) else { return nil }
            if let read = readOverrides[message.id] { message.isRead = read }
            if let flag = flagOverrides[message.id] { message.isFlagged = flag }
            if let verb = verbOverrides[message.id] { message.verb = verb }
            return message
        }
    }

    /// Mail moved to Archive or Deleted Items in this run, newest move first,
    /// with the reads and flags applied. Call with the lock held.
    private func moved(_ ids: [String], _ prefix: String) -> [MockFixtures.Message] {
        let saved = removed
        removed = []
        defer { removed = saved }
        let all = inbox(prefix) + sentItems(prefix) + junk(prefix)
            + MockFixtures.folderMail.keys.sorted().flatMap { folderNatives($0, prefix) }
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    /// Mail that started in a custom folder. Call with the lock held.
    private func folderNatives(_ folder: String, _ prefix: String) -> [MockFixtures.Message] {
        (MockFixtures.folderMail[folder] ?? []).enumerated().compactMap { index, message in
            var message = message
            message.id = "\(folder)-\(index)"
            guard message.id.hasPrefix(prefix), !removed.contains(message.id) else { return nil }
            if let read = readOverrides[message.id] { message.isRead = read }
            if let flag = flagOverrides[message.id] { message.isFlagged = flag }
            return message
        }
    }

    /// Moves, junk, emptying, the folder tree, counts and headers (M20, M21). Nil for any other
    /// request. Call with the lock held.
    private func listActionReply(_ request: String, prefix: String) -> (Data, Int)? {
        let ids = Self.matches(#"<t:ItemId Id="([^"]+)""#, in: request)
        let wellKnown = { (name: String) in MockFixtures.wellKnownID(name, prefix: prefix) }
        let elsewhere = { self.archived + self.trashed + self.junked + self.restored + self.filed.values.flatMap { $0 } }
        if request.contains("<m:MoveItem>") {
            guard let folder = Self.firstMatch(#"<m:ToFolderId><t:(?:Distinguished)?FolderId Id="([^"]+)""#, in: request) else { return nil }
            for id in ids { place(id, in: folder, prefix: prefix) }
            return ok(MockFixtures.moved(ids, operation: "MoveItem"))
        }
        // Read and flag for many rows at once (M20): one ItemChange per item.
        if request.contains("<m:UpdateItem"), request.components(separatedBy: "<t:ItemChange>").count > 2 {
            let read = Self.firstMatch("<t:IsRead>(true|false)</t:IsRead>", in: request)
            let flag = Self.firstMatch("<t:FlagStatus>(\\w+)</t:FlagStatus>", in: request)
            for id in ids {
                if let read { readOverrides[id] = read == "true" }
                if let flag { flagOverrides[id] = flag == "Flagged" }
            }
            return ok(MockFixtures.success("UpdateItem"))
        }
        if request.contains("<m:MarkAsJunk") {
            let junk = request.contains(#"IsJunk="true""#)
            for id in ids { place(id, in: junk ? "junkemail" : "inbox", prefix: prefix) }
            return ok(MockFixtures.moved(ids, operation: "MarkAsJunk"))
        }
        if request.contains("<m:EmptyFolder") {
            if request.contains(#"Id="deleteditems""#) {
                trashed = []
            } else if request.contains(#"Id="junkemail""#) {
                for message in moved(junked, prefix) + junk(prefix) { place(message.id, in: "deleteditems", prefix: prefix) }
            }
            return ok(MockFixtures.success("EmptyFolder"))
        }
        if request.contains("<m:FindFolder"), request.contains(#"Traversal="Deep""#),
           !request.contains("archivemsgfolderroot") {
            return ok(MockFixtures.findFolderTree(prefix: prefix))
        }
        if request.contains("<m:GetFolder>"), request.contains(#"DistinguishedFolderId Id="drafts""#) {
            return ok(MockFixtures.getFolders(SOAP.wellKnownNames.map { (wellKnown($0), 0) }))
        }
        if request.contains("<m:GetFolder>"), request.contains("folder:TotalCount") {
            let count = request.contains(#"Id="deleteditems""#) ? trashed.count : moved(junked, prefix).count + junk(prefix).count
            return ok(MockFixtures.getFolders([(wellKnown("count"), mode == .empty ? 0 : count)]))
        }
        if request.contains("<m:GetItem>"), request.contains("item:InternetMessageHeaders"), let id = ids.first {
            let all = inbox(prefix) + junk(prefix) + moved(elsewhere(), prefix)
            let header = all.first { $0.id == id }.flatMap(MockFixtures.unsubscribeHeader(for:))
            return ok(MockFixtures.headers(id: id, unsubscribe: header))
        }
        return nil
    }

    /// Takes an item out of wherever it is and puts it in `folder`, a distinguished name or a
    /// folder id. Mail that started in that folder simply stops being removed. Lock held.
    private func place(_ id: String, in folder: String, prefix: String) {
        removed.insert(id)
        archived.removeAll { $0 == id }
        trashed.removeAll { $0 == id }
        junked.removeAll { $0 == id }
        restored.removeAll { $0 == id }
        for key in filed.keys { filed[key]?.removeAll { $0 == id } }
        let wellKnown = { (name: String) in MockFixtures.wellKnownID(name, prefix: prefix) }
        let isJunkNative = id.hasPrefix("\(prefix)-junk-")
        let isSentNative = id.hasPrefix("\(prefix)-sent-")
        let isInboxNative = !isJunkNative && !isSentNative && !id.hasPrefix("\(prefix)-folder-")
        switch folder {
        case "inbox", wellKnown("inbox"):
            if isInboxNative { removed.remove(id) } else { restored.insert(id, at: 0) }
        case "junkemail", wellKnown("junkemail"):
            if isJunkNative { removed.remove(id) } else { junked.insert(id, at: 0) }
        case "deleteditems", wellKnown("deleteditems"):
            trashed.insert(id, at: 0)
        case "\(prefix)-archive":
            archived.insert(id, at: 0)
        default:
            if id.hasPrefix("\(folder)-") || (isSentNative && folder == "sentitems") {
                removed.remove(id)
            } else {
                filed[folder, default: []].insert(id, at: 0)
            }
        }
    }

    /// The fixture Junk Email. Call with the lock held.
    private func junk(_ prefix: String) -> [MockFixtures.Message] {
        let base = prefix == "team" ? [] : MockFixtures.workJunk
        return base.enumerated().compactMap { index, message in
            var message = message
            message.id = "\(prefix)-junk-\(index)"
            guard !removed.contains(message.id) else { return nil }
            if let read = readOverrides[message.id] { message.isRead = read }
            if let flag = flagOverrides[message.id] { message.isFlagged = flag }
            return message
        }
    }

    /// The fixture Sent Items, with the same changes applied. Call with the lock held.
    private func sentItems(_ prefix: String) -> [MockFixtures.Message] {
        let base = prefix == "team" ? [] : MockFixtures.workSent
        return base.enumerated().compactMap { index, message in
            var message = message
            message.id = "\(prefix)-sent-\(index)"
            guard !removed.contains(message.id) else { return nil }
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
        /// A meeting email's `ItemClass`, and the mock calendar event it is about.
        var meetingClass: String? = nil
        var event: String? = nil
        /// Sent Items only: the recipients' names, as `item:DisplayTo` lists them.
        var to: String? = nil
        /// `item:Importance`: High, Normal or Low.
        var importance = "Normal"
        /// PidTagLastVerbExecuted: 102 replied, 103 replied to all, 104 forwarded.
        var verb: Int? = nil
        /// PidTagMessageToMe: the sample user is on the To line.
        var toMe = true
        /// `item:Size` in bytes.
        var size = 18_000
        /// The files beyond the body's own images: name, content type, bytes.
        var files: [(String, String, Int)] = []

        var element: String {
            switch meetingClass {
            case let itemClass? where itemClass.contains("Request"): return "MeetingRequest"
            case let itemClass? where itemClass.contains("Canceled"): return "MeetingCancellation"
            case .some: return "MeetingResponse"
            case nil: return "Message"
            }
        }
    }

    static let workInbox: [Message] = [
        Message(sender: "People Operations", address: "people@example.com",
                subject: "یادآوری: خودارزیابی نیم‌سال را هنوز ثبت نکرده‌اید | مهلت تا پایان هفته",
                preview: "همکار گرامی سلام، دورهٔ ارزیابی عملکرد نیم‌سال آغاز شده است و فرم خودارزیابی شما هنوز تکمیل نشده است.",
                hoursAgo: 1.5, importance: "High", toMe: false, size: 42_000),
        Message(sender: "Omid Karimi", address: "omid@example.org",
                subject: "Invitation: Quarterly planning",
                preview: "Sunday 10:00 to 12:00, Room Blue. Planning for next quarter; bring your team's list.",
                hoursAgo: 0.8, meetingClass: "IPM.Schedule.Meeting.Request", event: "ev-next-planning"),
        Message(sender: "Build Server", address: "ci@example.com",
                subject: "Nightly build 2417 passed",
                preview: "All 312 tests passed in 14 minutes. No new warnings. Artifacts are attached to the run.",
                hoursAgo: 5, isRead: true, importance: "Low", toMe: false, size: 9_000),
        // An answer to the user's meeting, which Exchange sends with no preview: a two-line row.
        Message(sender: "Omid Karimi", address: "omid@example.org",
                subject: "Accepted: Quarterly planning", preview: "",
                hoursAgo: 6, isRead: true, meetingClass: "IPM.Schedule.Meeting.Resp.Pos", event: "ev-next-planning"),
        Message(sender: "Narges Ahmadi", address: "narges@example.com",
                subject: "Canceled: BW | Design system update",
                preview: "Moving this to next month, when the audit is in.",
                hoursAgo: 8, meetingClass: "IPM.Schedule.Meeting.Canceled", event: "ev-sat-update"),
        Message(sender: "Sara Rahimi", address: "sara.rahimi@example.com",
                subject: "Design review notes and the updated spacing tokens",
                preview: "Hi, attached are the notes from Tuesday. Two open points: the chip height on compact density, and whether the divider stays.",
                hoursAgo: 26, isFlagged: true, hasAttachments: true, verb: 102, size: 1_240_000,
                files: [("Review notes.txt", "text/plain", 92), ("Spacing tokens v3.pdf", "application/pdf", 1_180_000),
                        ("Chip heights.sketch", "application/octet-stream", 640_000)]),
        Message(sender: "Sara Rahimi", address: "sara.rahimi@example.com",
                subject: "Tentative: ds demo alignment",
                preview: "I have a clash at six; would seven work?",
                hoursAgo: 30, isRead: true, meetingClass: "IPM.Schedule.Meeting.Resp.Tent", event: "ev-sun-demo"),
        Message(sender: "واحد فناوری اطلاعات", address: "it@example.com",
                subject: "قطعی برنامه‌ریزی‌شده سرویس ایمیل، پنجشنبه ساعت ۲۲",
                preview: "سرویس ایمیل برای به‌روزرسانی از ساعت ۲۲ تا ۲۳ در دسترس نخواهد بود. Outlook و موبایل هر دو متأثر می‌شوند.",
                hoursAgo: 50, isRead: true),
        Message(sender: "Travel Desk", address: "travel@example.com",
                subject: "Your booking is confirmed",
                preview: "Reference QX-4471. Check-in opens 24 hours before departure.",
                hoursAgo: 24 * 5, isRead: true, hasAttachments: true, size: 310_000,
                files: [("Booking QX-4471.pdf", "application/pdf", 288_000)]),
        Message(sender: "Newsletter", address: "news@example.net",
                subject: "This month in product: three launches and a retrospective",
                preview: "Read the highlights, then the full write-up from each team.",
                hoursAgo: 24 * 21, isRead: true, toMe: false, size: 96_000),
        Message(sender: "Finance", address: "finance@example.com",
                subject: "Year-end expense deadline",
                preview: "Please submit remaining receipts before the books close.",
                hoursAgo: 24 * 380, isRead: true, verb: 104),
    ]

    /// What the sample user sent: plain replies, a Persian one, and a forward with a file.
    static let workSent: [Message] = [
        Message(sender: "Sample User", address: "sample.user@example.com",
                subject: "Re: Design review notes and the updated spacing tokens",
                preview: "Thanks Sara. The chip height works for me; let us keep the divider for now.",
                hoursAgo: 2, isRead: true, to: "Sara Rahimi"),
        Message(sender: "Sample User", address: "sample.user@example.com",
                subject: "گزارش ماهانهٔ تیم طراحی | شهریور",
                preview: "سلام، گزارش شهریور پیوست است. خلاصه: سه مؤلفهٔ تازه و بازبینی رنگ‌ها.",
                hoursAgo: 26, isRead: true, hasAttachments: true, to: "Omid Karimi; Narges Ahmadi",
                files: [("گزارش شهریور.pdf", "application/pdf", 520_000)]),
        Message(sender: "Sample User", address: "sample.user@example.com",
                subject: "FW: Year-end expense deadline",
                preview: "Forwarding in case this did not reach the team list.",
                hoursAgo: 24 * 3, isRead: true, to: "Design Team"),
        Message(sender: "Sample User", address: "sample.user@example.com",
                subject: "Quarterly planning agenda",
                preview: "Here is the draft agenda for Sunday. Add anything by Thursday.",
                hoursAgo: 24 * 9, isRead: true, to: "Omid Karimi; Sara Rahimi; Narges Ahmadi"),
    ]

    static let workJunk: [Message] = [
        Message(sender: "Prize Desk", address: "winner@example.net",
                subject: "You have been selected for an exclusive reward",
                preview: "Confirm your details within 24 hours to claim it.",
                hoursAgo: 5),
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
                      <t:\(message.element)>
                        <t:ItemId Id="\(message.id.isEmpty ? "item-\(index)" : message.id)" ChangeKey="ck-\(index)"/>
                        <t:Subject>\(SOAP.escape(message.subject))</t:Subject>
                        <t:HasAttachments>\(message.hasAttachments)</t:HasAttachments>
                        <t:DateTimeReceived>\(formatter.string(from: now.addingTimeInterval(-message.hoursAgo * 3600)))</t:DateTimeReceived>
                        <t:Preview>\(SOAP.escape(message.preview))</t:Preview>
                        <t:From><t:Mailbox><t:Name>\(SOAP.escape(message.sender))</t:Name>\
            <t:EmailAddress>\(message.address)</t:EmailAddress><t:RoutingType>SMTP</t:RoutingType></t:Mailbox></t:From>
                        <t:IsRead>\(message.isRead)</t:IsRead>
                        <t:Flag><t:FlagStatus>\(message.isFlagged ? "Flagged" : "NotFlagged")</t:FlagStatus></t:Flag>
                        \(message.meetingClass.map { "<t:ItemClass>\($0)</t:ItemClass>" } ?? "")
                        \(message.to.map { "<t:DisplayTo>\(SOAP.escape($0))</t:DisplayTo>" } ?? "")
                        <t:Importance>\(message.importance)</t:Importance>
                        <t:Size>\(message.size)</t:Size>
                        \(message.verb.map { #"<t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x1081" PropertyType="Integer"/><t:Value>\#($0)</t:Value></t:ExtendedProperty>"# } ?? "")
                        <t:ExtendedProperty><t:ExtendedFieldURI PropertyTag="0x0057" PropertyType="Boolean"/><t:Value>\(message.toMe)</t:Value></t:ExtendedProperty>
                      </t:\(message.element)>
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

    /// Each item's files, as a `GetItem` of `item:Attachments` lists them: the body's inline
    /// image first (which the app leaves out), then the fixture's own files.
    static func attachmentLists(_ messages: [Message]) -> String {
        let items = messages.map { message in
            let files = message.files.enumerated().map { index, file in
                """
                <t:FileAttachment><t:AttachmentId Id="att-\(message.id)-\(index)"/>\
                <t:Name>\(SOAP.escape(file.0))</t:Name><t:ContentType>\(file.1)</t:ContentType>\
                <t:Size>\(file.2)</t:Size><t:IsInline>false</t:IsInline></t:FileAttachment>
                """
            }.joined()
            return """
                    <t:\(message.element)><t:ItemId Id="\(message.id)" ChangeKey="ck"/><t:Attachments>\
            <t:FileAttachment><t:AttachmentId Id="att-photo"/><t:Name>photo.png</t:Name><t:ContentType>image/png</t:ContentType>\
            <t:ContentId>photo@mock</t:ContentId><t:IsInline>true</t:IsInline></t:FileAttachment>\(files)</t:Attachments></t:\(message.element)>
            """
        }.joined(separator: "\n")
        return MockCalendar.wrap("GetItem", "<m:Items>\n\(items)\n</m:Items>")
    }

    /// Each invitation's time, place and answer, from its mock event.
    static func rowMeetings(_ rows: [(Message, MockCalendar.Event, String?)]) -> String {
        let formatter = ISO8601DateFormatter()
        let items = rows.map { message, event, answer in
            """
                    <t:MeetingRequest><t:ItemId Id="\(message.id)" ChangeKey="ck"/>\
            <t:Start>\(formatter.string(from: event.start))</t:Start><t:End>\(formatter.string(from: event.end))</t:End>\
            <t:IsAllDayEvent>\(event.isAllDay)</t:IsAllDayEvent><t:Location>\(SOAP.escape(event.location))</t:Location>\
            <t:MyResponseType>\(answer ?? "NoResponseReceived")</t:MyResponseType></t:MeetingRequest>
            """
        }.joined(separator: "\n")
        return MockCalendar.wrap("GetItem", "<m:Items>\n\(items)\n</m:Items>")
    }

    /// A meeting email's link to its event, absent once the event is gone.
    static func meetingLink(_ message: Message, event: String?) -> String {
        MockCalendar.wrap("GetItem", """
                  <m:Items>
                    <t:\(message.element)>
                      <t:ItemId Id="\(message.id)" ChangeKey="ck"/>
                      \(event.map { #"<t:AssociatedCalendarItemId Id="\#($0)" ChangeKey="ck"/>"# } ?? "")
                    </t:\(message.element)>
                  </m:Items>
        """)
    }

    /// An answer's proposed time: an hour after the event, as long as it.
    static func proposedTime(_ message: Message, event: MockCalendar.Event?) -> String {
        let formatter = ISO8601DateFormatter()
        let times = event.map { event in
            "<t:ProposedStart>\(formatter.string(from: event.start.addingTimeInterval(3600)))</t:ProposedStart>"
                + "<t:ProposedEnd>\(formatter.string(from: event.end.addingTimeInterval(3600)))</t:ProposedEnd>"
        } ?? ""
        return MockCalendar.wrap("GetItem", """
                  <m:Items>
                    <t:MeetingResponse>
                      <t:ItemId Id="\(message.id)" ChangeKey="ck"/>
                      \(times)
                    </t:MeetingResponse>
                  </m:Items>
        """)
    }

    /// The body a mock message opens to: its preview as the first paragraph, a second paragraph,
    /// an inline image by `cid:` and a remote 1x1 tracking pixel, so the reader shows both the
    /// inlined image and the "remote images are blocked" line.
    static func getItem(_ message: Message, now: Date = Date()) -> String {
        let received = ISO8601DateFormatter().string(from: now.addingTimeInterval(-message.hoursAgo * 3600))
        let rtl = TextDirection.firstStrong(in: message.preview) == .rightToLeft
        // An invitation sent with no description, as most are: the day preview takes the body.
        let html = message.meetingClass?.contains("Request") == true ? "<html><body></body></html>" : """
        <html><head><style>p { margin: 0 0 10px; }</style></head>
        <body dir="\(rtl ? "rtl" : "ltr")">
        \(message.sender == "Newsletter" || message.address == "it@example.com" ? MockFixtures.wideNewsletter : "")
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
                        \(html.contains("cid:logo") ? "" : "<!--")
                        <t:FileAttachment>
                          <t:AttachmentId Id="att-logo"/>
                          <t:Name>logo.png</t:Name>
                          <t:ContentType>image/png</t:ContentType>
                          <t:ContentId>logo@mock</t:ContentId>
                          <t:IsInline>true</t:IsInline>
                        </t:FileAttachment>
                        \(html.contains("cid:logo") ? "" : "-->")
                        \(message.hasAttachments ? fileAttachments : "")
                      </t:Attachments>
                      <t:DateTimeReceived>\(received)</t:DateTimeReceived>
                      <t:ToRecipients><t:Mailbox><t:Name>Sample User</t:Name><t:EmailAddress>sample.user@example.com</t:EmailAddress></t:Mailbox></t:ToRecipients>
                      \(message.hasAttachments ? "<t:CcRecipients><t:Mailbox><t:Name>Omid Karimi</t:Name><t:EmailAddress>omid@example.org</t:EmailAddress></t:Mailbox><t:Mailbox><t:Name>Ali Tavakoli</t:Name><t:EmailAddress>ali.tavakoli@example.com</t:EmailAddress></t:Mailbox></t:CcRecipients>" : "")
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
    /// reader zooms it to fit without changing any proportions. Also in the Persian IT message, a
    /// right-to-left body, where the overflow runs off the LEFT edge (the user's report).
    static let wideNewsletter = """
    <table width="600" cellpadding="0" cellspacing="0" style="background:#b8dcea"><tr><td align="center">
    <img src="cid:logo@mock" width="600" height="120" alt="banner">
    <p style="font-size:22px;margin:16px">A 600 pixel wide newsletter layout</p>
    </td></tr></table>
    """

    /// A 1600x800 photo-sized image in the mail that has attachments, to check the reader fits a
    /// large image to the text column, proportionally, with no sideways scroll.
    static let photoPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAABkAAAAMgCAIAAAD0ojkNAABFrklEQVR42u3YQQ3AIBREQYTVEU7wUz/1gAEskGwPe5jkKSDDP+zY79Rl33p0GS1cccUVV1xxJa644oorrrgSV381cAHLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK3HFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxxRUwXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccUVV8BwxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFldcAcMVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFjEgOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK66A4YorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664Ei0GLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcGLGLAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKtHDFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXHElrrjiyoAFloMlrrjiiiuuuBJXXHHFFVdciSsDFlgOFldciSuuuOKKK67EFVdcccWVAUtgOVhcccUVV6KFK6644oorrsQVVwYssBwsrsQVV1xxxRVX4oorrrjiiisZsMBysLjiiitxxRVXXHHFlbjiiiuuDFhgycHiiiuuuOKKK3HFFVdcccWVuDJggeVgccWVuOKKK6644kpcccUVV1wZsASWg8UVV1xxJa644oorrrgSV1xxZcACy8ESLVxxxRVXXHElrrjiiiuuuJIBCywHiyuuuBJXXHHFFVdciSuuuOLKgAWWHCyuuOKKK67EFVdcccUVV+KKKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiitxxRVXBiywHCxxxRVXXHHFlbjiiiuuuOKKK2AMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuBJXXHHFFVdciSuuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVX4oorrrjiiiuugOGKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHElAxZYDhZXXHElrrjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorA5bAcrC44oorrrgChiuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxZW44oorrgxYYMnB4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK664EldccWXAAsvB4goYrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdcccUVMAYssBwsrrjiSlxxxRVXXHElrrjiiisDFlhysLjiiiuuuBJXXHHFFVdciSuuDFhgOVhciSuuuOKKK67EFVdcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFFVfAcMUVV1wZsMCSg8UVV1xxxZW44oorrrjiSlxxZcACy8HiSlxxxRVXXHElrrjiiiuuuJIBCywHiyuuuBJXXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJq3DA8gQ+oU/IFVdccSWuuOKKK664EldccdWcAQssB4srrrjiSlxxxRVXXHElrrjiyoAFloMlrrjiiiuuuBJXXHHFFVdciSsDFlgOFldciSuuuOKKK67EFVdcccWVAQssYhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kq0cMUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBJXXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXooUrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WuOKKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuBItXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK3HFFVdcccWVuOKKK6644sqAhQtYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK66A4YorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuuAKGK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLjiChiuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxZcAiBiwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccUVV8BwxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVdcAcMVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbhKByxP4BP6hFxxxRVX4oorrrjiiitxxRVXzRmwwHKwuOKKK67EFVdcccUVV+KKK64MWGA5WOKKK6644oorccUVV1xxxZW4MmCB5WBxxZW44oorrrjiSlxxxRVXXBmwwCLGweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuRAtXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oorccUVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdccSVauOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkrrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4sr0cIVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFi4gOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaD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iiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbhKByxP4BP6hFxxxRVX4oorrrjiiitxxRVXzRmwwHKwuOKKK67EFVdcccUVV+KKK64MWGA5WOKKK6644oorccUVV1xxxZW4MmCB5WBxxZW44oorrrjiSlxxxRVXXBmwwCLGweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuRAtXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oorccUVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdccSVauOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkrrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4sr0cIVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFi4gOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK66A4YorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcGLGLAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXHEFDFdccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxxRUwXHHFFVdccSWuDFhgOVhccSWuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVXXIkrrrjiiiuuZMACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8UVV8BwxRVXXHHFlbjiiiuuuDJgCSwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJFgMWWA4WV1xxJa644oorrrgSV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKwMWMWA5WFxxxRVX4oorrrjiiitxxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSVauOKKK64MWGDJweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuuBJXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oor0cIVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdcccWVuOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkWrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdcccUVMAYssBwsrrjiSlxxxRVXXHElrrjiiisDFlhysLjiiiuuuBJXXHHFFVdciSuuDFhgOVhciSuuuOKKK67EFVdcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFFVfAcMUVV1wZsMCSg8UVV1xxxZW44oorrrjiSlxxZcACy8HiSlxxxRVXXHElrrjiiiuuuJIBCywHiyuuuBJXXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJq3TA8gQ+oU/IFVdccSWuuOKKK664EldccdWcAQssB4srrrjiSlxxxRVXXHElrrjiyoAFloMlrrjiiiuuuBJXXHHFFVdciSsDFlgOFldciSuuuOKKK67EFVdcccWVAQssYhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kq0cMUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBJXXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXooUrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WuOKKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuBItXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVX4sqABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK3HFFVdcccWVuOKKK6644sqAhQtYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK66A4YorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuuAKGK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLjiChiuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxZcAiBiwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccUVV8BwxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVdcAcMVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbhKByxP4BP6hFxxxRVX4oorrrjiiitxxRVXzRmwwHKwuOKKK67EFVdcccUVV+KKK64MWGA5WOKKK6644oorccUVV1xxxZW4MmCB5WBxxZW44oorrrjiSlxxxRVXXBmwwCLGweKKK6644kpcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuRAtXXHFlwALLwRJXXHHFFVdciSuuuOKKK67ElQELLAeLK67EFVdcccUVV+KKK6644sqAJbAcLK644oorccUVV1xxxRVX4oorAxZYDhZX4oorrrjiiitxxRVXXHHFlQxYYDlYXHHFlbjiiiuuuOJKXHHFFVcGLLDkYHHFFVdccSVauOKKK6644kpcGbDAcrC44kpcccUVV1xxJa644oorrgxYAsvB4oorrrgSV1xxxRVXXIkrrrgyYIHlYIkrrrjiiiuuuBJXXHHFFVdcyYAFloPFFVdciSuuuOKKK67EFVdccWXAAksOFldcccUVV+KKK6644oorccWVAQssB4sr0cIVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOJKXHHFFVdccSWuDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLgSV1xxxRVXXIkrrrjiiiuuDFi4gOVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiitxxRVXXHHFlbjiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxJQMWWA4WV1xxJa644oorrrjiChiuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBS2A5WFxxxRVX4oorrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccWVuOKKK64MWGDJweKKK6644oorYLjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVfiiiuuuOKKK3HFlQELLAeLK66A4YorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKK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uOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1yJK6644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXIkrrrjiiiuuxBVXXHHFFVcyYIHlYHHFFVfiiiuuuOKKK66A4YorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgyYIHlYHHFlbjiiiuuuOJKXHHFFVdcGbAEloPFFVdccSWuuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrriSAQssB4srrrgSV1xxxRVXXIkrrrjiyoAFlhwsrrjiiiuuuAKGK6644oorrsSVAQssB4srrsQVV1xxxRVX4oorrrjiyoAlsBwsrrjiiitxxRVXXHHFlbjiiisDFlgOlrjiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644kpcccUVVwYssORgccUVV1xxJa644oorrrgSV1wZsMBysLjiChiuuOKKK664EldcccUVVwYsgeVgccUVV1yJK6644oorrsQVV1wZsMBysMQVV1xxxRVX4oorrrjiiitxZcACy8HiiiuuxBVXXHHFFVfiiiuuuDJggSUHiyuuuOKKK3HFFVdcccWVuOLKgAWWg8WVuOKKK6644kpcccUVV1xxZcAiBiwHiyuuuOJKXHHFFVdccSWuuOLKgAWWgyWuuOKKK664EldcccUVV1yJKwMWWA4WV1yJK6644oorrsQVV1xxxZUBCyw5WFxxxRVXXIkrrrjiiiuuxBVXBiywHCyuxBVXXHHFFVfiiiuuuOKKKxmwwHKwuOKKK3HFFVdcccUVV8BwxRVXBiywHCxxxRVXXHHFlbjiiiuuuOJKXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1xxJa64MmCB5WBxJa644oorrrgSV1xxxRVXXMmABZaDxRVXXIkrrrjiiiuuxBVXXHFlwAJLDhZXXHHFFVdcAcMVV1xxxRVX4sqABZaDxRVX4oorrrjiiitxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdcccWVuOKKK6644koGLLAcLK644kpcccUVV1xxJa644oorAxZYcrC44oorrrgSV1xxxRVXXIkrrgxYYDlYXHEFDFdcccUVV1yJK6644oorA5bAcrC44oorrsQVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlWgxYIHlYHHFFVfiiiuuuOKKK3HFFVdcGbDAkoPFFVdcccWVuOKKK6644kpccWXAAsvB4kpcccUVV1xxJa644oorrrgyYBEDloPFFVdccSWuuOKKK664EldccWXAAsvBEldcccUVV1yJK6644oorrsSVAQssB4srrsQVV1xxxRVXooUrrrjiyoAFlhwsrrjiiiuuxBVXXHHFFVfiiisDFlgOFlfiiiuuuOKKK3HFFVdcccWVDFhgOVhcccWVuOKKK6644oorccUVVwYssBwsccUVV1xxxZW44oorrrjiSlwZsMBysLjiSlxxxRVXXHElrrjiiiuuDFgCy8HiiiuuuBItXHHFFVdccSWuuDJggeVgcSWuuOKKK664EldcccUVV1zJgAWWg8UVV1yJK6644oorrsQVV1xxZcACSw4WV1xxxRVXXIkrrrjiiiuuxJUBCywHiyuuxBVXXHHFFVfiiiuuuOLKgCWwHCyuuOKKK3HFFVdcccWVuOKKKwMWWA6WaOGKK6644oorccUVV1xxxZUMWGA5WFxxxZW44oorrrjiSlxxxRVXBiyw5GBxxRVXXHElrrjiiiuuuBJXXBmwwHKwuOJKXHHFFVdccSWuuOKKK64MWALLweKKK664EldcccUVV1yJK664MmCB5WCJK6644oorrsQVV1xxxRVXXAFjwALLweKKK67EFVdcccUVV+KKK664MmCBJQeLK6644oorccUVV1xxxZW44sqABZaDxZW44oorrrjiSlxxxRVXXHFlwBJYDhZXXHHFlbjiiiuuuOJKXHHFlQELLAdLXHHFFVdccSWuuOKKK664ElcGLLAcLK64EldcccUVV1xxBQxXXHHFlQELLDlYXHHFFVdciSuuuOKKK67EFVcGLLAcLK7EFVdcccUVV+KKK6644oorGbDAcrC44oorccUVV1xxxRVX4oorrgxYYDlY4oorrrjiiitxxRVXXHHFlbgKOxRexWU5PAq8AAAAAElFTkSuQmCC"

    /// The inline photo, plus one real attachment, for the message that has attachments.
    static let fileAttachments = """
    <t:FileAttachment>
      <t:AttachmentId Id="att-photo"/>
      <t:Name>photo.png</t:Name>
      <t:ContentType>image/png</t:ContentType>
      <t:ContentId>photo@mock</t:ContentId>
      <t:IsInline>true</t:IsInline>
    </t:FileAttachment>
    <t:FileAttachment>
      <t:AttachmentId Id="att-notes"/>
      <t:Name>Review notes.txt</t:Name>
      <t:ContentType>text/plain</t:ContentType>
      <t:Size>\(notesText.utf8.count)</t:Size>
      <t:IsInline>false</t:IsInline>
    </t:FileAttachment>
    """

    static let notesText = "Design review notes (sample)\n\n1. Chip height on compact density.\n2. Keep or drop the divider.\n"

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
                <t:FileAttachment>
                  <t:AttachmentId Id="att-notes"/>
                  <t:Name>Review notes.txt</t:Name>
                  <t:ContentType>text/plain</t:ContentType>
                  <t:Content>\(Data(notesText.utf8).base64EncodedString())</t:Content>
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

    /// The message the mock stream delivers.
    static let arrival = Message(sender: "Omid Karimi", address: "omid@example.org",
                                 subject: "Quick question about tomorrow's review",
                                 preview: "Are we still on for 10:00? I can move it if the room is taken.",
                                 hoursAgo: 0)

    static let subscribe = """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <m:SubscribeResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <m:ResponseMessages>
            <m:SubscribeResponseMessage ResponseClass="Success">
              <m:ResponseCode>NoError</m:ResponseCode>
              <m:SubscriptionId>mock-subscription</m:SubscriptionId>
            </m:SubscribeResponseMessage>
          </m:ResponseMessages>
        </m:SubscribeResponse>
      </s:Body>
    </s:Envelope>
    """

    /// One streaming envelope: a keep-alive, an event, or the server's Closed at timeout.
    static func streamingEnvelope(event: String?, closed: Bool = false) -> String {
        let notification = event.map {
            """
            <m:Notifications><m:Notification>\
            <t:SubscriptionId>mock-subscription</t:SubscriptionId>\
            <t:\($0)><t:TimeStamp>2026-09-24T12:00:00Z</t:TimeStamp>\
            <t:ItemId Id="new" ChangeKey="ck"/><t:ParentFolderId Id="inbox" ChangeKey="f"/></t:\($0)>\
            </m:Notification></m:Notifications>
            """
        } ?? ""
        return """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\
        <s:Body><m:GetStreamingEventsResponse \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><m:ResponseMessages>\
        <m:GetStreamingEventsResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>\
        \(notification)<m:ConnectionStatus>\(closed ? "Closed" : "OK")</m:ConnectionStatus>\
        </m:GetStreamingEventsResponseMessage></m:ResponseMessages></m:GetStreamingEventsResponse>\
        </s:Body></s:Envelope>
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
