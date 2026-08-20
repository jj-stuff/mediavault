import Foundation

/// Turns URL loading failures into something a person can act on.
///
/// Two *separate* iOS subsystems can block a connection to a self-hosted server,
/// and confusing them wastes hours because the advice for one does nothing for the
/// other:
///
/// - **App Transport Security** objects to the *scheme*. It surfaces as a TLS
///   error and is configured in `Info.plist`.
/// - **Local Network Privacy** objects to the *destination*. It is a user
///   permission, applies to any RFC 1918 / link-local / `.local` address, and is
///   entirely unaffected by ATS settings.
///
/// LNP has no public error constant. It reports `NSURLErrorNotConnectedToInternet`,
/// the same code as a genuinely offline device — so the destination has to be
/// inspected to tell the two apart.
nonisolated enum NetworkErrorMessage {

    /// - Parameter url: the address that failed. Required to distinguish a local
    ///   network permission denial from being offline.
    static func explain(_ error: Error, url: URL? = nil) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nsError.localizedDescription }

        let isLocalTarget = url?.host().map(RemoteServerService.isLocalAddress) ?? false

        return switch nsError.code {
        case NSURLErrorNotConnectedToInternet where isLocalTarget:
            localNetworkBlocked

        case NSURLErrorNotConnectedToInternet:
            "This device isn't on a network."

        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            """
            iOS blocked the connection for not using HTTPS. This build should \
            allow it — make sure you reinstalled the app after the last update \
            rather than just relaunching it.
            """

        case NSURLErrorCannotFindHost:
            "That hostname couldn't be found. Check the address for typos."

        case NSURLErrorCannotConnectToHost where isLocalTarget:
            """
            Nothing answered on that address and port.

            """ + localNetworkBlocked

        case NSURLErrorCannotConnectToHost:
            """
            Nothing answered on that address and port. The server may be stopped, \
            or the port may be wrong.
            """

        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            """
            The secure connection failed. If the server runs plain HTTP, put \
            http:// at the front of the address.
            """

        case NSURLErrorTimedOut where isLocalTarget:
            """
            The server didn't respond in time.

            """ + localNetworkBlocked

        case NSURLErrorTimedOut:
            "The server didn't respond in time."

        case NSURLErrorNetworkConnectionLost:
            "The connection dropped mid-request."

        default:
            "\(nsError.localizedDescription) (URLError \(nsError.code))"
        }
    }

    /// The tell for this one is that the same address loads fine in Safari — a
    /// system app, exempt from the restriction.
    ///
    /// The restart matters and is not superstition: Apple's DTS has confirmed a
    /// caching bug where a denied permission is retained in memory and survives
    /// deleting and reinstalling the app. Rebooting is the only thing that clears
    /// it.
    static let localNetworkBlocked = """
        iOS is most likely blocking access to devices on your network. If this \
        address works in Safari but not here, that is what it is — Safari is a \
        system app and isn't subject to the restriction.

        Fix it in this order:

        1. Restart the iPhone. A denied permission gets cached in a way that \
        survives reinstalling the app, and rebooting is the only thing that \
        clears it.
        2. Check Settings › Privacy & Security › Local Network and switch \
        MediaVault on.
        3. If MediaVault isn't listed there at all, delete the app, restart the \
        phone, then reinstall so iOS asks again — and allow it this time.
        """
}
