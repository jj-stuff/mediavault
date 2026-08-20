import AVFoundation
import UIKit

/// A view whose backing layer *is* the `AVPlayerLayer`.
///
/// Backing the layer directly avoids a second layer to keep in sync and means the
/// player surface resizes with the view for free.
final class FeedPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // Safe: `layerClass` above guarantees the type.
        layer as! AVPlayerLayer
    }

    let progressBar: UIProgressView = {
        let bar = UIProgressView(progressViewStyle: .default)
        bar.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        bar.progressTintColor = .white
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player

        addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
