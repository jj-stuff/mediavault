import Foundation

/// Turns URL loading failures into something a person can act on.
///
/// The system messages are useless for diagnosis — "The operation couldn't be
/// completed" covers a blocked cleartext request, a wrong port, and a firewall
/// equally. Shared by the sign-in sheet and the connection test so both name the
/// same cause the same way.
nonisolated enum NetworkErrorMessage {

    static func explain(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nsError.localizedDescription }

        return switch nsError.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            """
            iOS blocked the connection for not using HTTPS. This build should \
            allow it — make sure you reinstalled the app after the last update, \
            rather than just relaunching it.
            """
        case NSURLErrorCannotFindHost:
            "That hostname couldn't be found. Check the address for typos."
        case NSURLErrorCannotConnectToHost:
            """
            Nothing answered on that address and port. The server may be stopped, \
            the port may be wrong, or this device may be on a different network \
            from the server.
            """
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            """
            The secure connection failed. If the server runs plain HTTP, put \
            http:// at the front of the address.
            """
        case NSURLErrorTimedOut:
            """
            The server didn't respond in time. This usually means a firewall is \
            dropping the connection, or this device is on a different network \
            (or a guest network) from the server.
            """
        case NSURLErrorNotConnectedToInternet:
            "This device isn't on a network."
        case NSURLErrorNetworkConnectionLost:
            "The connection dropped mid-request."
        default:
            "\(nsError.localizedDescription) (URLError \(nsError.code))"
        }
    }
}
