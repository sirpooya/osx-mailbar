import Foundation
import Testing
@testable import Mailbar

/// The list features of 2026-11-16: filters, sort, date groups, the row's marks, its files,
/// its invitation buttons and the sender's initials.
@Suite struct ListOptionsRequestTests {
    @Test func filtersAreANDedWithTheFolderAndKeepTheSchemaOrder() throws {
        var options = MailListOptions()
        options.filters = [.unread, .attachments]
        let body = SOAP.findMessages(in: .flagged, options: options, limit: 50, modern: true)
        #expect(body.contains("<m:Restriction><t:And>"))
        #expect(body.contains(#"FieldURI="message:IsRead"/><t:FieldURIOrConstant><t:Constant Value="false"/>"#))
        #expect(body.contains(#"FieldURI="item:HasAttachments""#))
        #expect(body.contains(#"PropertyTag="0x1090""#))
        let root = try XMLTree.parse(SOAP.envelope(.exchange2013, body: body))
        let find = try #require(root.first("FindItem"))
        #expect(find.children.map(\.name) == ["ItemShape", "IndexedPageItemView", "Restriction", "SortOrder", "ParentFolderIds"])
    }

    @Test func oneFilterNeedsNoAndAndAFilterThatMeansNothingThereIsDropped() {
        var options = MailListOptions()
        options.filters = [.toMe]
        #expect(SOAP.findMessages(options: options, limit: 50, modern: true).contains(#"<m:Restriction><t:IsEqualTo><t:ExtendedFieldURI PropertyTag="0x0057""#))
        // Everything in Sent Items was sent by me: no restriction, and it is the plain list.
        #expect(!SOAP.findMessages(in: .sent, options: options, limit: 50, modern: true).contains("<m:Restriction>"))
        #expect(options.isDefault(in: .sent))
        #expect(!options.isDefault(in: .inbox))
    }

    @Test func eachOrderFallsBackToNewestFirst() {
        for sort in MailSort.allCases where sort != .date {
            let orders = sort.fieldOrders(in: .inbox)
            #expect(orders.hasSuffix(#"<t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder>"#))
        }
        #expect(MailSort.sender.fieldOrders(in: .inbox).contains("0x0C1A"))
        #expect(MailSort.sender.fieldOrders(in: .sent).contains("0x0E04"))
        #expect(MailSort.sender.title(in: .sent) == "To")
    }

    @Test func theRowAsksForImportanceSizeAndTheMarks() {
        let body = SOAP.findMessages(limit: 50, modern: false)
        for field in ["item:Importance", "item:Size", #"PropertyTag="0x1081""#, #"PropertyTag="0x0057""#] {
            #expect(body.contains(field))
        }
    }

    @Test func rowFieldsAreParsed() throws {
        var high = MockFixtures.Message(sender: "A", address: "a@example.com", subject: "S", preview: "", hoursAgo: 1)
        high.importance = "High"
        high.verb = 103
        high.size = 4096
        var low = MockFixtures.Message(sender: "B", address: "b@example.com", subject: "T", preview: "", hoursAgo: 2)
        low.importance = "Low"
        low.toMe = false
        let messages = try EWSResponse.messages(from: Data(MockFixtures.findItem([high, low]).utf8))
        #expect(messages[0].importance == .high)
        #expect(messages[0].lastVerb == .repliedAll)
        #expect(messages[0].isToMe)
        #expect(messages[0].size == 4096)
        #expect(messages[1].importance == .low)
        #expect(messages[1].lastVerb == nil)
        #expect(!messages[1].isToMe)
    }

    @Test func subjectsSortWithoutTheirPrefixes() {
        #expect(MailSort.normalized("RE: FW: Budget") == "Budget")
        #expect(MailSort.normalized("Fwd:Agenda") == "Agenda")
        #expect(MailSort.normalized("Note: this stays") == "Note: this stays")
    }

    @Test func dateGroupsFollowOutlook() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        // Wednesday 19 November 2025, noon.
        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 11, day: 19, hour: 12)))
        func title(_ days: Int) -> String {
            MailDateGroup.title(for: calendar.date(byAdding: .day, value: -days, to: now)!, now: now, calendar: calendar)
        }
        #expect(title(0) == "Today")
        #expect(title(1) == "Yesterday")
        #expect(!["Today", "Yesterday", "Last Week"].contains(title(3)))   // Sunday: a day name
        #expect(title(5) == "Last Week")
        #expect(title(12) == "Two Weeks Ago")
        #expect(title(19) == "Three Weeks Ago")
        #expect(title(40) == "Last Month")
        #expect(title(400) == "Older")
    }

    @Test func initialsAndColoursAreStable() {
        #expect(SenderAvatar.initials(of: "Sara Rahimi") == "SR")
        #expect(SenderAvatar.initials(of: "ci@example.com") == "C")
        #expect(SenderAvatar.initials(of: "(Build) Server") == "BS")
        #expect(SenderAvatar.initials(of: "") == "?")
        #expect(SenderAvatar.color(for: "Sara Rahimi") == SenderAvatar.color(for: "sara rahimi"))
    }
}

@MainActor
@Suite struct ListOptionsStoreTests {
    private let work = MockMode.accounts[0]

    private func makeStore() async -> MailStore {
        let accounts = AccountStore(inMemory: MockMode.accounts, passwords: MockMode.passwords)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0)))
        store.selectedAccountID = work.id
        await store.refresh()
        return store
    }

    @Test func theUnreadFilterIsAskedOfTheServer() async {
        let store = await makeStore()
        store.listOptions.filters = [.unread]
        await store.loadOptionsList()
        let found = store.optionsPhase.messages
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { !$0.isRead })
        #expect(found.count == store.state(for: work.id).messages.filter { !$0.isRead }.count)
    }

    @Test func sortingBySizePutsTheLargestFirstAndActionsReachTheList() async throws {
        let store = await makeStore()
        store.listOptions.sort = .size
        await store.loadOptionsList()
        let found = store.optionsPhase.messages
        #expect(found.map(\.size) == found.map(\.size).sorted(by: >))
        let first = try #require(found.first)
        await store.setFlag(!first.isFlagged, message: first.id, in: work.id)
        #expect(store.optionsPhase.messages.first?.isFlagged == !first.isFlagged)
        await store.delete(message: first.id, in: work.id)
        #expect(!store.optionsPhase.messages.contains { $0.id == first.id })
    }

    @Test func closingThePopoverDropsTheFiltersButKeepsTheOrder() async {
        let store = await makeStore()
        store.listOptions.filters = [.flagged]
        store.listOptions.sort = .subject
        store.popoverClosed()
        #expect(store.listOptions.filters.isEmpty)
        #expect(store.listOptions.sort == .subject)
    }

    @Test func rowsGetTheirFilesButNotTheBodysOwnImages() async throws {
        let store = await makeStore()
        let messages = store.state(for: work.id).messages
        await store.loadRowDetails(for: messages, accountID: work.id)
        let review = try #require(messages.first { $0.subject.hasPrefix("Design review") })
        let files = try #require(store.rowAttachments[review.id])
        #expect(files.map(\.name) == ["Review notes.txt", "Spacing tokens v3.pdf", "Chip heights.sketch"])
        #expect(store.rowAttachments.values.joined().allSatisfy { $0.name != "photo.png" })
    }

    @Test func anInvitationRowCanBeAnsweredFromTheList() async throws {
        let store = await makeStore()
        let messages = store.state(for: work.id).messages
        await store.loadRowDetails(for: messages, accountID: work.id)
        let invitation = try #require(messages.first { $0.isMeetingRequest })
        let meeting = try #require(store.rowMeetings[invitation.id])
        #expect(meeting.response == nil)
        #expect(meeting.end > meeting.start)
        await store.answerFromRow(.accept, message: invitation.id, in: work.id)
        #expect(store.rowMeetings[invitation.id]?.response == "Accept")
        #expect(store.message(invitation.id, in: work.id)?.isRead == true)
        #expect(store.actionError == nil)
    }
}
