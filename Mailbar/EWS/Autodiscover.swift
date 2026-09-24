import Foundation

/// Finds an account's EWS address and display name from just the email address and password,
/// the way Outlook does when you add an Exchange account.
///
/// Plain-old-XML Autodiscover, the protocol every on-prem Exchange since 2007 serves:
/// POST a small request to `https://autodiscover.<domain>/autodiscover/autodiscover.xml` (then
/// `https://<domain>/...`), authenticated like EWS itself, and read `EwsUrl` and `DisplayName`
/// from the reply. Only these two HTTPS addresses under the email's own domain are tried. The
/// plain-HTTP redirect method and DNS SRV lookup are left out: the first would put a request on
/// the wire unencrypted, and both exist mainly for hosted mail, which this app does not target.
///
/// The user name is not in the reply, so it is guessed: the short name before the `@` first
/// (what Outlook for Mac's sheet shows), then the full address. Whichever the server accepts is
/// the one kept.
struct Autodiscover: Sendable {
    let transport: any EWSTransport

    struct Result: Equatable, Sendable {
        let ewsURL: URL
        let displayName: String
        let username: String
    }

    enum Failure: Error, Equatable {
        /// Not an address this can work from.
        case invalidEmail
        /// Every candidate rejected every user name.
        case passwordRejected
        /// No candidate answered as Autodiscover. The user enters the server by hand.
        case notFound(String)
    }

    static func endpoints(for email: String) -> [URL] {
        guard let domain = domain(of: email) else { return [] }
        return ["https://autodiscover.\(domain)/autodiscover/autodiscover.xml",
                "https://\(domain)/autodiscover/autodiscover.xml"].compactMap(URL.init(string:))
    }

    static func usernames(for email: String) -> [String] {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@") else { return [] }
        let local = String(trimmed[..<at])
        return local.isEmpty ? [trimmed] : [local, trimmed]
    }

    static func domain(of email: String) -> String? {
        let parts = email.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].contains("/"), !parts[1].contains(":") else { return nil }
        return parts[1].lowercased()
    }

    func discover(email: String, password: String) async throws -> Result {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        let endpoints = Self.endpoints(for: trimmed)
        guard !endpoints.isEmpty else { throw Failure.invalidEmail }

        var sawRejection = false
        var lastProblem = "No Autodiscover service answered for \(Self.domain(of: trimmed) ?? "this domain")."

        for endpoint in endpoints {
            for username in Self.usernames(for: trimmed) {
                let credential = EWSCredential(username: username, password: password)
                do {
                    let (data, status) = try await transport.send(Self.request(email: trimmed),
                                                                  to: endpoint, credential: credential)
                    if status == 401 { sawRejection = true; continue }
                    guard status == 200 else {
                        lastProblem = "\(endpoint.host ?? "The server") answered \(status)."
                        break
                    }
                    let (url, name) = try Self.parse(data)
                    return Result(ewsURL: url, displayName: name, username: username)
                } catch let error as URLError where error.code == .userCancelledAuthentication {
                    sawRejection = true
                    continue
                } catch let error as URLError {
                    lastProblem = EWSError.from(urlError: error).message(host: endpoint.host ?? "The server")
                    // Nothing listens here; the next user name will not change that.
                    break
                } catch let error as EWSError {
                    lastProblem = error.message(host: endpoint.host ?? "The server")
                    break
                } catch {
                    lastProblem = error.localizedDescription
                    break
                }
            }
        }
        throw sawRejection ? Failure.passwordRejected : Failure.notFound(lastProblem)
    }

    static func request(email: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006">
          <Request>
            <EMailAddress>\(SOAP.escape(email))</EMailAddress>
            <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
          </Request>
        </Autodiscover>
        """.utf8)
    }

    /// The EWS address and display name. `EXPR` (Outlook Anywhere, reachable from outside) is
    /// preferred over `EXCH` (the internal address), so the account keeps working off the office
    /// network when the company publishes one; the two are often the same URL anyway.
    static func parse(_ data: Data) throws -> (URL, String) {
        let root: XMLTreeNode
        do { root = try XMLTree.parse(data) } catch {
            throw EWSError.invalidResponse("The Autodiscover reply was not valid XML.")
        }
        if let error = root.first("Error") {
            let message = error.child("Message")?.trimmedText ?? "Autodiscover returned an error."
            throw EWSError.server(message)
        }
        var byType: [String: URL] = [:]
        var anyURL: URL?
        for node in root.all("Protocol") {
            guard let raw = node.child("EwsUrl")?.trimmedText,
                  let url = Account.normalizedEndpoint(raw) else { continue }
            let type = node.child("Type")?.trimmedText ?? ""
            if byType[type] == nil { byType[type] = url }
            if anyURL == nil { anyURL = url }
        }
        guard let url = byType["EXPR"] ?? byType["EXCH"] ?? anyURL else {
            throw EWSError.invalidResponse("Autodiscover answered, but without an EWS address.")
        }
        let name = root.path("Response", "User", "DisplayName")?.trimmedText
            ?? root.first("DisplayName")?.trimmedText ?? ""
        return (url, name)
    }
}
