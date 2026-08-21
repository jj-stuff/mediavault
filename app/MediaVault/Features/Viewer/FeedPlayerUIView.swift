import AVFoundation
import UIKit

/// A view whose backing layer *is* the `AVPlayerLayer`.
///
/// Backing the layer directly avoids a second layer to keep in sync and means the
/// player surface resizes with the view for free.
///
/// It used to also own a progress bar pinned to its bottom edge. That bar has moved
/// out to `FeedScrubBar` in the SwiftUI overlay: down here it was below the tab bar
/// and the home indicator, and a `UIProgressView` cannot be dragged anyway.
final class FeedPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Safe: `layerClass` above guarantees the type.
        layer as! AVPlayerLayer
    }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
