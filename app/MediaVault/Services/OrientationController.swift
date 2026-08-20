import UIKit

/// Controls which interface orientations the app allows, so landscape media can be
/// viewed full-bleed without unlocking rotation everywhere else.
///
/// The static `supportedOrientations` is a deliberate exception to injecting
/// everything: `application(_:supportedInterfaceOrientationsFor:)` is a UIKit
/// callback on an app delegate that UIKit instantiates itself, so there is no
/// injection point. Keeping the storage here — rather than on the delegate — at
/// least means views talk to this type and never to `AppDelegate`.
@Observable
final class OrientationController {

    /// Read by `AppDelegate`. Nothing else should touch it directly.
    nonisolated(unsafe) static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    private(set) var isLandscape = false

    func rotateToLandscape() {
        apply(.landscape)
        isLandscape = true
    }

    func restorePortrait() {
        apply(.portrait)
        isLandscape = false
    }

    private func apply(_ mask: UIInterfaceOrientationMask) {
        Self.supportedOrientations = mask

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        // Without this the bar orientation can lag a frame behind the geometry change.
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
