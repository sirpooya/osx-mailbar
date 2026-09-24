import Foundation

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
}

/// The real transport.
///
/// No cache of any kind: an ephemeral configuration keeps cookies and credentials in memory only,
/// and the URL cache is removed outright, so no response (which is mail) ever reaches the disk.
struct URLSessionTransport: EWSTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        // The credential is answered per request by the task delegate below, never from a store.
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
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

/// Answers the server's authentication challenge with the account's user name and password.
///
/// On-prem Exchange offers some mix of Negotiate, NTLM and Basic on the EWS virtual directory.
/// `URLSession` runs the NTLM and Negotiate handshakes itself once given a `URLCredential`; this
/// only decides what to hand it:
/// - first attempt at any of them: the credential, never persisted;
/// - Negotiate failed (no Kerberos realm reachable, say): step aside so the next offered scheme,
///   usually NTLM, gets its turn;
/// - anything else failed: cancel, which surfaces as `passwordRejected` rather than a retry loop.
private final class ChallengeResponder: NSObject, URLSessionTaskDelegate, Sendable {
    private let credential: EWSCredential

    init(credential: EWSCredential) {
        self.credential = credential
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        switch method {
        case NSURLAuthenticationMethodServerTrust:
            // System trust only. There is deliberately no override here.
            return (.performDefaultHandling, nil)

        case NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodNegotiate,
             NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest:
            if challenge.previousFailureCount == 0 {
                let answer = URLCredential(user: credential.username,
                                           password: credential.password,
                                           persistence: .none)
                return (.useCredential, answer)
            }
            if method == NSURLAuthenticationMethodNegotiate {
                return (.rejectProtectionSpace, nil)
            }
            return (.cancelAuthenticationChallenge, nil)

        default:
            // A client certificate request, for one. Not supported, and not silently answered.
            return (.performDefaultHandling, nil)
        }
    }
}
