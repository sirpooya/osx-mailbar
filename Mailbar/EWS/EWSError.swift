import Foundation

/// Everything that can go wrong talking to Exchange, kept as separate cases on purpose.
///
/// The worst bug this app can have is showing a failure as an empty inbox. There is no case here
/// a view can render as "no mail", and `InboxState` has no path from an error to `.empty`.
///
/// No case ever carries the password or a request body. Messages come from status codes and the
/// server's own `MessageText`.
enum EWSError: Error, Equatable, Sendable {
    /// 401, or the server kept challenging after the password was offered.
    case passwordRejected
    /// DNS, connection or timeout. On an internal host this usually means the VPN is off.
    case unreachable(String)
    /// The certificate was refused. Not the same as unreachable, and never bypassed.
    case tlsFailure(String)
    /// The URL answered, but not as EWS: a 404, an HTML login page, a redirect elsewhere.
    case notEWS(String)
    /// EWS answered with an error of its own: a SOAP fault or `ResponseClass="Error"`.
    case server(String)
    /// The reply parsed as XML but not as the response that was asked for.
    case invalidResponse(String)
    case unexpected(String)

    static func from(urlError: URLError) -> EWSError {
        switch urlError.code {
        case .userCancelledAuthentication, .userAuthenticationRequired:
            return .passwordRejected
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff:
            return .unreachable("This Mac has no network connection.")
        case .cannotFindHost, .dnsLookupFailed:
            return .unreachable("The server name does not resolve.")
        case .cannotConnectToHost, .timedOut:
            return .unreachable("The server did not answer.")
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            return .tlsFailure("The server's certificate was not accepted.")
        default:
            return .unexpected(urlError.localizedDescription)
        }
    }

    /// One line a person can act on. Settings and the popover both use it.
    func message(host: String) -> String {
        switch self {
        case .passwordRejected:
            return "\(host) rejected the user name or password."
        case .unreachable(let reason):
            return "\(reason) If \(host) is internal, check the VPN."
        case .tlsFailure(let reason):
            return reason
        case .notEWS(let reason):
            return "\(reason) Check the server address; it usually ends in /EWS/Exchange.asmx."
        case .server(let message), .invalidResponse(let message), .unexpected(let message):
            return message
        }
    }
}
