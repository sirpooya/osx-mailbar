import AppKit
import Foundation
import Observation

/// Someone the People field or a recipient field can offer: from the Exchange directory, the
/// people directory, or the inbox's senders.
struct PersonSuggestion: Identifiable, Hashable, Sendable {
    let name: String
    let address: String
    /// A distribution group (Exchange's `PublicDL` or `PrivateDL`), which can be expanded.
    var isGroup = false
    /// Team and department, from the people directory, when it knows the person.
    var detail = ""

    var id: String { address.lowercased() }
    var display: String { name.isEmpty ? address : name }
}

/// One person from the people directory the user set in Settings.
struct DirectoryPerson: Identifiable, Hashable, Sendable {
    let name: String
    let address: String
    let team: String
    let department: String
    let role: String
    /// Only on the directory's own host, and nil for its "default" placeholder.
    let avatar: URL?

    var id: String { address.lowercased() }
    var detail: String { [team, department].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// Decoding the directory's JSON. Kept generic on purpose: nothing about any one company's
/// endpoint is baked in, only the shape most people lists share.
enum DirectoryJSON {
    /// `{ "items": [...] }`, `{ "users": [...] }`, `{ "data": [...] }` or a bare array. Each entry
    /// needs a name and a work email; people marked departed are left out.
    static func people(from data: Data, baseURL: URL) throws -> [DirectoryPerson] {
        let object = try JSONSerialization.jsonObject(with: data)
        let entries: [[String: Any]]
        if let list = object as? [[String: Any]] {
            entries = list
        } else if let top = object as? [String: Any],
                  let list = ["items", "users", "people", "data", "results"].lazy.compactMap({ top[$0] as? [[String: Any]] }).first {
            entries = list
        } else {
            throw DirectoryError.notAList
        }
        var seen = Set<String>()
        return entries.compactMap { entry -> DirectoryPerson? in
            guard !isDeparted(entry), let address = email(in: entry), seen.insert(address.lowercased()).inserted else { return nil }
            return DirectoryPerson(name: string(entry["name"]) ?? string(entry["displayName"]) ?? "",
                                   address: address,
                                   team: string(entry["team"]) ?? "",
                                   department: string(entry["department"]) ?? "",
                                   role: string(entry["role"]) ?? string(entry["title"]) ?? "",
                                   avatar: avatarURL(string(entry["avatar"]) ?? string(entry["photo"]), base: baseURL))
        }
    }

    /// The work address: `workEmail` or `email` first, else any field whose name ends in "email"
    /// that holds an address.
    static func email(in entry: [String: Any]) -> String? {
        let preferred = ["workEmail", "email", "mail"].compactMap { string(entry[$0]) }
        let others = entry.keys.sorted().filter { $0.lowercased().hasSuffix("email") }.compactMap { string(entry[$0]) }
        return (preferred + others).first(where: Recipients.isValid)
    }

    /// Photos come only from the directory's own host, so setting a directory never sends
    /// Mailbar anywhere else. A file named "default" is the site's placeholder, not a face.
    static func avatarURL(_ text: String?, base: URL) -> URL? {
        guard let text, !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL,
              url.host?.lowercased() == base.host?.lowercased(), url.scheme == base.scheme else { return nil }
        let file = url.deletingPathExtension().lastPathComponent.lowercased()
        return file == "default" || file.isEmpty ? nil : url
    }

    private static func isDeparted(_ entry: [String: Any]) -> Bool {
        ["departed", "inactive", "left", "former"].contains(string(entry["employment"])?.lowercased() ?? "")
            || entry["active"] as? Bool == false
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// No cache of any kind, as for the mail server.
private enum DirectoryHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
}

enum DirectoryError: LocalizedError {
    case notHTTPS
    case status(Int)
    case notAList

    var errorDescription: String? {
        switch self {
        case .notHTTPS: return "Use an https:// address."
        case .status(let code): return "The directory answered with HTTP \(code)."
        case .notAList: return "The address did not return a list of people."
        }
    }
}

/// The people directory from Settings (a JSON list of people with their team and department),
/// for the Team and Department pickers and for photos. Held in memory only, like everything
/// else: the list is read again after ten minutes or a relaunch, photos are fetched each time a
/// view shows them and kept by that view alone.
@MainActor
@Observable
final class PeopleDirectory {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var people: [DirectoryPerson] = []
    private(set) var phase: Phase = .idle
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loadedFrom: String?
    /// The read in progress, which every caller waits on rather than starting its own.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private let fetch: @Sendable (URL) async throws -> Data
    @ObservationIgnored private let address: () -> String

    init(address: @escaping () -> String = { UserDefaults.standard.string(forKey: Keys.peopleDirectoryURL) ?? "" },
         fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        self.address = address
        self.fetch = fetch ?? { url in
            let (data, response) = try await DirectoryHTTP.session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DirectoryError.status(http.statusCode)
            }
            return data
        }
    }

    /// The directory's address, when one is set and usable.
    var url: URL? {
        let text = address().trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    var isConfigured: Bool { url != nil }

    var departments: [String] { Self.sortedNames(people.map(\.department)) }

    /// Teams, those of one department when one is given.
    func teams(in department: String?) -> [String] {
        Self.sortedNames(people.filter { department == nil || $0.department == department }.map(\.team))
    }

    func person(for address: String) -> DirectoryPerson? {
        let key = address.lowercased()
        return people.first { $0.id == key }
    }

    /// People whose name, address or team starts a word with what is typed.
    func matches(_ token: String, limit: Int = 4) -> [DirectoryPerson] {
        let needle = token.lowercased().trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        return Array(people.filter { person in
            person.address.lowercased().hasPrefix(needle)
                || "\(person.name) \(person.team)".lowercased().split(separator: " ").contains { $0.hasPrefix(needle) }
                || person.name.lowercased().hasPrefix(needle)
        }.prefix(limit))
    }

    /// Reads the list when there is none yet, it is ten minutes old, or the address changed.
    func loadIfNeeded() async {
        guard let url else { people = []; phase = .idle; return }
        if loadedFrom == url.absoluteString, let loadedAt, Date().timeIntervalSince(loadedAt) < 600, phase == .loaded { return }
        await load()
    }

    func load() async {
        if let inFlight { return await inFlight.value }
        let task = Task { await read() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func read() async {
        guard let url else {
            people = []
            phase = address().trimmingCharacters(in: .whitespaces).isEmpty ? .idle : .failed(DirectoryError.notHTTPS.localizedDescription)
            return
        }
        phase = .loading
        do {
            let data = try await fetch(url)
            let found = try DirectoryJSON.people(from: data, baseURL: url)
            people = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadedAt = Date()
            loadedFrom = url.absoluteString
            phase = .loaded
        } catch is CancellationError {
            phase = people.isEmpty ? .idle : .loaded
        } catch let error as DirectoryError {
            phase = .failed(error.localizedDescription)
        } catch is DecodingError {
            phase = .failed(DirectoryError.notAList.localizedDescription)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            phase = .failed(DirectoryError.notAList.localizedDescription)
        } catch {
            phase = .failed("Could not reach the directory: \(error.localizedDescription)")
        }
    }

    /// Forgets the list, when the address changes.
    func reset() {
        people = []
        phase = .idle
        loadedAt = nil
        loadedFrom = nil
    }

    /// The person's photo from the directory. Never kept here (no image is cached anywhere):
    /// the view that shows it holds it.
    func avatar(for address: String) async -> NSImage? {
        guard let url = person(for: address)?.avatar else { return nil }
        guard let data = try? await fetch(url) else { return nil }
        return NSImage(data: data)
    }

    private static func sortedNames(_ names: [String]) -> [String] {
        Array(Set(names.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
