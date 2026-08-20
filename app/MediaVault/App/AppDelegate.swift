import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    /// UIKit asks the delegate — not any view — which orientations are allowed, so
    /// this forwards to the controller that owns the decision.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationController.supportedOrientations
    }
}
