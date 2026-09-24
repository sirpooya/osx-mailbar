import Foundation
import os

/// The user name and password for one request. Built from the Keychain right before the request
/// and dropped right after it. Never logged, never stored on a long-lived object.
struct EWSCredential: Sendable {
    let username: String
    let password: String
}

/// Sends one SOAP request and returns the body and HTTP status. A protocol so mock mode and the
/// tests can answer with fixtures instead of a server.
protocol EWSTransport: Sendable {
    func send(_ body: Data, to url: URL, credential: EWSCredential) async throws -> (Data, Int)

    /// A long-lived request whose reply is a sequence of SOAP envelopes written as they happen:
    /// EWS streaming notifications (M11). Yields each complete envelope. A non-200 reply yields
    /// its whole body once and finishes, with the status alongside.
    func stream(_ body: Data, to url: URL, credential: EWSCredential) async throws
        -> (AsyncThrowingStream<Data, Error>, Int)
}

extension EWSTransport {
    /// Transports that cannot stream (the tests' stubs) say so, and the app keeps polling.
    func stream(_ body: Data, to url: URL, credential: EWSCredential) async throws
        -> (AsyncThrowingStream<Data, Error>, Int) {
        throw EWSError.server("Streaming is not supported by this transport.")
    }
}

/// The real transport.
///
/// No cache of any kind: an ephemeral configuration keeps cookies and credentials in memory only,
/// and the URL cache is removed outright, so no response (which is mail) ever reaches the disk.
struct URLSessionTransport: EWSTransport {
    private let session: URLSession
    /// For streaming only: the same no-cache setup, but a connection may sit quiet for up to the
    /// 30 minutes EWS allows between envelopes' batches, so the idle timeout is set past that.
    /// It shares the cookie jar (in memory) with `session`: a load-balanced Exchange pins a
    /// subscription to one server by cookie, and the stream must reach the server that made it.
    private let streamSession: URLSession

    static let streamIdleTimeout: TimeInterval = 35 * 60

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        // The credential is answered per request by the task delegate below, never from a store.
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)

        let streaming = URLSessionConfiguration.ephemeral
        streaming.urlCache = nil
        streaming.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        streaming.urlCredentialStorage = nil
        streaming.httpCookieStorage = configuration.httpCookieStorage
        streaming.timeoutIntervalForRequest = Self.streamIdleTimeout
        streaming.timeoutIntervalForResource = Self.streamIdleTimeout
        streamSession = URLSession(configuration: streaming)
    }

    func stream(_ body: Data, to url: URL, credential: EWSCredential) async throws
        -> (AsyncThrowingStream<Data, Error>, Int) {
        var request = URLRequest(url: url, timeoutInterval: Self.streamIdleTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/xml", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await streamSession.bytes(for: request,
                                                             delegate: ChallengeResponder(credential: credential))
        guard let http = response as? HTTPURLResponse else {
            throw EWSError.unexpected("The server's reply was not HTTP.")
        }
        let status = http.statusCode
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let reader = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        // An envelope is complete at its closing tag, whatever prefix the server
                        // gives the SOAP namespace.
                        if status == 200, byte == UInt8(ascii: ">"), EnvelopeSplitter.endsWithClosingEnvelope(buffer) {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return (stream, status)
    }

    func send(_ body: Data, to url: URL, credential: EWSCredential) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request,
                                                      delegate: ChallengeResponder(credential: credential))
        guard let http = response as? HTTPURLResponse else {
            throw EWSError.unexpected("The server's reply was not HTTP.")
        }
        // EWS answers in XML. HTML means something else took the request: a web login page, a
        // proxy's error page, or the wrong path on the right server.
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("text/html") && http.statusCode != 401 {
            throw EWSError.notEWS("That address answered with a web page, not Exchange Web Services.")
        }
        return (data, http.statusCode)
    }
}

/// Finds the end of one SOAP envelope in a byte stream: `</Envelope>` or `</s:Envelope>` and so on.
enum EnvelopeSplitter {
    static func endsWithClosingEnvelope(_ buffer: Data) -> Bool {
        let tail = String(decoding: buffer.suffix(48), as: UTF8.self)
        guard tail.hasSuffix("Envelope>"), let open = tail.range(of: "</", options: .backwards) else { return false }
        let name = tail[open.upperBound...].dropLast() // "s:Envelope" or "Envelope"
        return name == "Envelope" || name.hasSuffix(":Envelope")
    }
}

/// Which offered scheme gets the password, decided per request.
///
/// `URLSession` walks the schemes the server offers in its own order (Negotiate, then NTLM, then
/// Basic, on Exchange 2019) and hands each one to the delegate. Two things about that walk shape
/// the rules:
/// - `previousFailureCount` counts failures across all schemes, not per scheme. NTLM arrives with
///   a count of 1 once Negotiate has failed, so reading the count as "NTLM failed" meant NTLM was
///   never tried at all.
/// - Every refused password is one failed logon against the domain's lockout counter, and
///   Autodiscover sends two user names. Trying all three schemes would spend up to six attempts
///   on one mistyped password.
///
/// So the password goes to exactly one scheme per request. Negotiate is passed over the first
/// time it is offered, since a Mac off the domain has no Kerberos realm and NTLM (or Basic) comes
/// next; if Negotiate comes back around with nothing else offered, it gets the password then.
/// Once the one attempt has been made, every further challenge is declined, and the request ends
/// with the server's own 401.
struct ChallengePolicy: Sendable {
    private var seen: Set<String> = []
    private var answered = false

    static let passwordMethods: Set<String> = [NSURLAuthenticationMethodNTLM,
                                               NSURLAuthenticationMethodNegotiate,
                                               NSURLAuthenticationMethodHTTPBasic,
                                               NSURLAuthenticationMethodHTTPDigest]

    /// Whether this challenge should get the password.
    mutating func shouldAnswer(_ method: String) -> Bool {
        let firstSight = seen.insert(method).inserted
        guard !answered else { return false }
        if method == NSURLAuthenticationMethodNegotiate && (firstSight || seen.count > 1) {
            return false
        }
        answered = true
        return true
    }
}

/// Answers the server's authentication challenge with the account's user name and password, as
/// `ChallengePolicy` decides. `URLSession` runs the NTLM and Negotiate handshakes itself once
/// given a `URLCredential`. A declined challenge is never a cancel: cancelling surfaced as a
/// plain `cancelled` error, which the rest of the app rightly ignores, so a refused password
/// showed up as nothing at all.
private final class ChallengeResponder: NSObject, URLSessionTaskDelegate, Sendable {
    private let credential: EWSCredential
    private let policy = OSAllocatedUnfairLock(initialState: ChallengePolicy())

    init(credential: EWSCredential) {
        self.credential = credential
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            // System trust only. There is deliberately no override here.
            return (.performDefaultHandling, nil)
        }
        guard ChallengePolicy.passwordMethods.contains(method) else {
            // A client certificate request, for one. Not supported, and not silently answered.
            return (.performDefaultHandling, nil)
        }
        guard policy.withLock({ $0.shouldAnswer(method) }) else {
            return (.rejectProtectionSpace, nil)
        }
        return (.useCredential, URLCredential(user: credential.username,
                                              password: credential.password,
                                              persistence: .none))
    }
}
