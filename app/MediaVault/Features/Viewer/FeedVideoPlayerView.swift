import AVFoundation
import SwiftUI

/// Lightweight player surface for the For You feed.
///
/// Deliberately owns no playback state: the `AVPlayer` is created, looped, played,
/// and paused by `FeedPlayerPool`, which outlives this view. All this does is show
/// the player's layer and toggle play on tap. Position is drawn by `FeedScrubBar`.
struct FeedVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeUIView(context: Context) -> FeedPlayerUIView {
        let view = FeedPlayerUIView(player: player)
        view.playerLayer.videoGravity = videoGravity

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap)
        )
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: FeedPlayerUIView, context: Context) {
        uiView.playerLayer.videoGravity = videoGravity

        // The pool can hand the same view a different player when the feed shifts.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            context.coordinator.player = player
        }
    }

    final class Coordinator: NSObject {
        var player: AVPlayer

        init(player: AVPlayer) {
            self.player = player
        }

        @objc func handleTap() {
            player.rate == 0 ? player.play() : player.pause()
        }
    }
}
