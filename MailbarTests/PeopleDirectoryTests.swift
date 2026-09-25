import Foundation
import Testing
@testable import Mailbar

@Suite struct DirectoryJSONTests {
    private let base = URL(string: "https://people.example.com/api/users")!

    private func decode(_ json: String) throws -> [DirectoryPerson] {
        try DirectoryJSON.people(from: Data(json.utf8), baseURL: base)
    }

    @Test func readsItemsWithTeamDepartmentAndARelativePhoto() throws {
        let people = try decode("""
        {"items":[{"name":"Narges Ahmadi","workEmail":"narges@example.com","team":"Design",
                   "department":"Product","role":"Designer","avatar":"/images/avatars/narges.png"}]}
        """)
        #expect(people.count == 1)
        #expect(people[0].address == "narges@example.com")
        #expect(people[0].detail == "Design · Product")
        #expect(people[0].avatar?.absoluteString == "https://people.example.com/images/avatars/narges.png")
    }

    @Test func anyFieldEndingInEmailIsTheAddressAndABareArrayIsAList() throws {
        let people = try decode(#"[{"name":"Ali","companyEmail":"ali@example.com","team":"Platform"}]"#)
        #expect(people.map(\.address) == ["ali@example.com"])
    }

    @Test func departedPeopleAndPeopleWithoutAnAddressAreLeftOut() throws {
        let people = try decode("""
        {"items":[{"name":"Kaveh","email":"kaveh@example.com","employment":"departed"},
                  {"name":"Nobody","email":"not an address"},
                  {"name":"Mina","email":"mina@example.com","employment":null}]}
        """)
        #expect(people.map(\.name) == ["Mina"])
    }

    @Test func thePlaceholderAndPhotosOnOtherHostsAreNotPhotos() {
        #expect(DirectoryJSON.avatarURL("/images/avatars/default.png", base: base) == nil)
        #expect(DirectoryJSON.avatarURL("https://tracker.example.net/a.png", base: base) == nil)
        #expect(DirectoryJSON.avatarURL("http://people.example.com/a.png", base: base) == nil)
        #expect(DirectoryJSON.avatarURL("https://people.example.com/a.png", base: base) != nil)
    }

    @Test func somethingThatIsNotAListIsAnError() {
        #expect(throws: DirectoryError.self) { try decode(#"{"message":"hello"}"#) }
    }
}

@Suite struct GroupRecipientTests {
    @Test func expandingSwapsTheGroupForItsMembersInPlace() {
        let text = Recipients.expanding("a@example.com, team@example.com, z@example.com", group: "TEAM@example.com",
                                        into: ["b@example.com", "a@example.com", "c@example.com"],
                                        elsewhere: "c@example.com")
        #expect(text == "a@example.com, b@example.com, z@example.com, ")
    }

    @Test func appendingSkipsAddressesAlreadyInEitherField() {
        #expect(Recipients.appending(["b@example.com", "c@example.com", "B@example.com"], to: "a@example.com",
                                     elsewhere: "c@example.com") == "a@example.com, b@example.com, ")
    }

    @Test func resolveNamesMarksDistributionGroups() throws {
        let people = try EWSResponse.resolvedNames(from: Data(MockCalendar.resolveResponse("design").utf8))
        #expect(people.first { $0.address == "designteam@example.com" }?.isGroup == true)
        let person = try EWSResponse.resolvedNames(from: Data(MockCalendar.resolveResponse("sara").utf8))
        #expect(person.map(\.isGroup) == [false])
    }

    @Test func expandDLRequestNamesTheGroup() {
        let body = CalendarSOAP.expandGroup("team&co@example.com")
        #expect(body.contains("<m:ExpandDL>"))
        #expect(body.contains("<t:EmailAddress>team&amp;co@example.com</t:EmailAddress>"))
    }
}

@MainActor
@Suite struct PeopleAndGroupsStoreTests {
    private func makeStore() async -> (MailStore, UUID) {
        let accounts = AccountStore(inMemory: [MockMode.accounts[0]], passwords: MockMode.passwords)
        let directory = PeopleDirectory(address: { MockDirectory.address }, fetch: MockDirectory.fetch)
        let store = MailStore(accounts: accounts, client: EWSClient(transport: MockTransport(mode: .inbox, newMailAfter: 0)),
                              directory: directory)
        await store.refresh()
        return (store, MockMode.accounts[0].id)
    }

    @Test func aGroupExpandsToItsMembersWithTheNestedGroupMarked() async throws {
        let (store, account) = await makeStore()
        await store.checkGroups(["designteam@example.com"], accountID: account)
        #expect(store.isGroup("DesignTeam@example.com"))
        #expect(store.groupName("designteam@example.com") == "Design Team")
        let result = try await store.expandGroup("designteam@example.com", accountID: account)
        #expect(result.complete)
        #expect(result.members.count == 5)
        #expect(result.members.first { $0.address == "design-leads@example.com" }?.isGroup == true)
        #expect(store.isGroup("design-leads@example.com"))
        #expect(result.members.first { $0.address == "narges@example.com" }?.detail == "Design · Product")
    }

    @Test func suggestionsCarryTheirTeamAndLeaveDepartedPeopleOut() async {
        let (store, account) = await makeStore()
        let found = await store.peopleSuggestions(for: "design", excluding: "", accountID: account)
        #expect(found.contains { $0.address == "designteam@example.com" && $0.isGroup })
        #expect(found.contains { $0.address == "narges@example.com" && $0.detail == "Design · Product"
                                  && $0.role == "Product Designer" })
        #expect(!found.contains { $0.address == "kaveh.shams@example.com" })
    }

    @Test func theDirectoryListsTeamsByDepartment() async {
        let (store, _) = await makeStore()
        await store.directory.load()
        #expect(store.directory.phase == .loaded)
        #expect(store.directory.departments == ["Engineering", "Operations", "Product"])
        #expect(store.directory.teams(in: "Product") == ["Design"])
        #expect(await store.directory.avatar(for: "narges@example.com") != nil)
        #expect(await store.directory.avatar(for: "sara.rahimi@example.com") == nil)
    }
}
