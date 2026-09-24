import Foundation

/// The EWS operations the app performs, one method each. Stateless: the caller passes the
/// endpoint and credential every time, and keeps whatever it learns (the server version) itself.
struct EWSClient: Sendable {
    let transport: any EWSTransport

    /// How many inbox rows the list holds.
    static let pageSize = 50

    init(transport: any EWSTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// The unread count, plus the server version. The account test in Settings is exactly this.
    func inboxStatus(at url: URL, credential: EWSCredential) async throws -> InboxStatus {
        let data = try await send(SOAP.envelope(.exchange2010SP2, body: SOAP.getInbox),
                                  to: url, credential: credential)
        return try EWSResponse.inboxStatus(from: data)
    }

    /// The newest inbox items, newest first. On a pre-2013 server the previews come back empty
    /// and are filled by `previews(for:)`.
    func inboxMessages(at url: URL,
                       credential: EWSCredential,
                       modern: Bool,
                       limit: Int = EWSClient.pageSize) async throws -> [MailMessage] {
        let body = SOAP.findInbox(limit: limit, modern: modern)
        let data = try await send(SOAP.envelope(modern ? .exchange2013 : .exchange2010SP2, body: body),
                                  to: url, credential: credential)
        return try EWSResponse.messages(from: data)
    }

    /// One-line previews built from text bodies, for servers without `item:Preview`.
    func previews(for ids: [String], at url: URL, credential: EWSCredential) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let data = try await send(SOAP.envelope(.exchange2010SP2, body: SOAP.textBodies(ids: ids)),
                                  to: url, credential: credential)
        return try EWSResponse.previews(from: data)
    }

    private func send(_ body: Data, to url: URL, credential: EWSCredential) async throws -> Data {
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.send(body, to: url, credential: credential)
        } catch let error as EWSError {
            throw error
        } catch let error as URLError {
            throw EWSError.from(urlError: error)
        } catch {
            throw EWSError.unexpected(error.localizedDescription)
        }

        switch status {
        case 200:
            return data
        case 401:
            throw EWSError.passwordRejected
        case 403:
            throw EWSError.server("Exchange refused access (403). EWS may be turned off for this mailbox.")
        case 404:
            throw EWSError.notEWS("Nothing answers at that path on the server (404).")
        case 500:
            // EWS reports its own errors as a SOAP fault with status 500. Read the fault's words;
            // only a 500 with no readable fault is the server genuinely failing.
            if let root = try? XMLTree.parse(data) {
                _ = try EWSResponse.responseMessages(in: root)
            }
            throw EWSError.server("Exchange had an internal error (500).")
        default:
            throw EWSError.server("Exchange answered with status \(status).")
        }
    }
}
