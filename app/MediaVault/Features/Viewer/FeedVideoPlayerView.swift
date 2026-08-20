import AVFoundation
import SwiftUI

/// Lightweight player surface for the For You feed.
///
/// Deliberately owns no playback state: the `AVPlayer` is created, looped, played,
/// and paused by `FeedPlayerPool`, which outlives this view. All this does is show
/// the player's layer, mirror progress, and toggle play on tap.
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

        context.coordinator.observeProgress(on: view)
        return view
    }

    func updateUIView(_ uiView: FeedPlayerUIView, context: Context) {
        uiView.playerLayer.videoGravity = videoGravity

        // The pool can hand the same view a different player when the feed shifts.
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            context.coordinator.rebind(to: player, view: uiView)
        }
    }

    static func dismantleUIView(_ uiView: FeedPlayerUIView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject {
        // `nonisolated(unsafe)` so `deinit` — which is never actor-isolated — can
        // still tear the observer down. Both are only ever touched on the main
        // actor in normal operation.
        nonisolated(unsafe) private var player: AVPlayer
        nonisolated(unsafe) private var timeObserver: Any?

        init(player: AVPlayer) {
            self.player = player
        }

        deinit {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
        }

        func observeProgress(on view: FeedPlayerUIView) {
            let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak view, weak player] time in
                guard let view, let player,
                      let duration = player.currentItem?.duration.seconds,
                      duration.isFinite, duration > 0
                else { return }
                view.progressBar.progress = Float(time.seconds / duration)
            }
        }

        func rebind(to newPlayer: AVPlayer, view: FeedPlayerUIView) {
            invalidate()
            player = newPlayer
            observeProgress(on: view)
        }

        func invalidate() {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }

        @objc func handleTap() {
            player.rate == 0 ? player.play() : player.pause()
        }
    }
}
