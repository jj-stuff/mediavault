import UIKit

/// Safe-area numbers for views that have deliberately opted out of the safe area.
///
/// The For You feed ignores the safe area so video fills the screen edge to edge.
/// That also zeroes the insets SwiftUI hands to everything inside it, so its overlay
/// — the profile header at the top, the actions and the scrubber at the bottom —
/// had nothing to position against and ended up under the Dynamic Island and under
/// the tab bar. These read the real values back off the window.
enum ScreenInsets {

    /// Height of the floating tab bar. UIKit does not publish it, and SwiftUI folds
    /// it into a safe-area inset this screen has given up, so it is a constant.
    static let tabBarHeight: CGFloat = 56

    static var top: CGFloat { window?.safeAreaInsets.top ?? 47 }
    static var bottom: CGFloat { window?.safeAreaInsets.bottom ?? 34 }

    /// Room the feed overlay leaves below itself: home indicator plus tab bar.
    static var feedBottomClearance: CGFloat { bottom + tabBarHeight }

    /// Room a scrolling grid leaves below its last row, so the tab bar does not sit
    /// on top of content the user then cannot scroll any further to reach.
    static var gridBottomClearance: CGFloat { tabBarHeight + 12 }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }
}
