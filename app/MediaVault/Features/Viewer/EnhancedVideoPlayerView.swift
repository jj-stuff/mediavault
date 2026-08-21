import AVKit
import SwiftUI

/// The detail-screen video player: scrubber, double-tap skip zones, and
/// press-and-hold to double speed.
///
/// Built on `AVPlayerViewController` with its own controls hidden, because the
/// stock controls cannot express the skip-zone and speed-boost gestures.
struct EnhancedVideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var player: AVPlayer?
    let skipDuration: Double
    @Binding var isLandscape: Bool
    let shouldPlay: Bool

    /// Width of each edge zone that accepts a double-tap to skip, as a fraction of
    /// the player's width.
    private static let skipZoneWidthFraction: CGFloat = 0.3
    private static let controlsHeight: CGFloat = 70
    /// Gap between the scrubber and the home indicator. The container ignores the
    /// safe area so the video can be full-bleed, which also zeroes the container's
    /// own safe-area guide — so the inset is read off the window instead.
    private static let controlsBottomGap: CGFloat = 16
    private static let forwardBufferDuration: TimeInterval = 5

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = .black

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = Self.forwardBufferDuration

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none

        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.showsPlaybackControls = false
        playerViewController.videoGravity = isLandscape ? .resizeAspectFill : .resizeAspect

        container.addChild(playerViewController)
        container.view.addSubview(playerViewController.view)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            playerViewController.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        playerViewController.didMove(toParent: container)

        let controlsView = VideoControlsView(player: player, skipDuration: skipDuration)
        controlsView.isHidden = isLandscape
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(controlsView)
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            controlsView.bottomAnchor.constraint(
                equalTo: container.view.bottomAnchor,
                constant: -(ScreenInsets.bottom + Self.controlsBottomGap)
            ),
            controlsView.heightAnchor.constraint(equalToConstant: Self.controlsHeight)
        ])

        context.coordinator.controlsView = controlsView
        context.coordinator.playerViewController = playerViewController

        configureGestures(on: container, controlsView: controlsView, coordinator: context.coordinator)
        context.coordinator.observeLoop(for: playerItem, player: player)

        // Publishing to a binding has to be deferred: this runs during a view
        // update, and writing state synchronously here would re-enter it.
        DispatchQueue.main.async {
            self.player = player
            if shouldPlay { player.play() }
        }

        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.playerViewController?.videoGravity =
            isLandscape ? .resizeAspectFill : .resizeAspect
        context.coordinator.controlsView?.isHidden = isLandscape
        if shouldPlay { player?.play() } else { player?.pause() }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: $player) }

    // MARK: - Gestures

    private func configureGestures(
        on container: UIViewController,
        controlsView: VideoControlsView,
        coordinator: Coordinator
    ) {
        let singleTap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        container.view.addGestureRecognizer(singleTap)

        let leftZone = makeZoneView(in: container, below: controlsView)
        let rightZone = makeZoneView(in: container, below: controlsView)

        NSLayoutConstraint.activate([
            leftZone.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            leftZone.topAnchor.constraint(equalTo: container.view.topAnchor),
            leftZone.bottomAnchor.constraint(equalTo: controlsView.topAnchor, constant: -8),
            leftZone.widthAnchor.constraint(
                equalTo: container.view.widthAnchor,
                multiplier: Self.skipZoneWidthFraction
            ),

            rightZone.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            rightZone.topAnchor.constraint(equalTo: container.view.topAnchor),
            rightZone.bottomAnchor.constraint(equalTo: controlsView.topAnchor, constant: -8),
            rightZone.widthAnchor.constraint(
                equalTo: container.view.widthAnchor,
                multiplier: Self.skipZoneWidthFraction
            )
        ])

        attachZoneGestures(
            to: leftZone,
            doubleTapAction: #selector(VideoControlsView.leftDoubleTapped),
            controlsView: controlsView,
            coordinator: coordinator,
            requiring: singleTap
        )
        attachZoneGestures(
            to: rightZone,
            doubleTapAction: #selector(VideoControlsView.rightDoubleTapped),
            controlsView: controlsView,
            coordinator: coordinator,
            requiring: singleTap
        )
    }

    private func makeZoneView(in container: UIViewController, below sibling: UIView) -> UIView {
        let zone = UIView()
        zone.translatesAutoresizingMaskIntoConstraints = false
        zone.backgroundColor = .clear
        container.view.insertSubview(zone, belowSubview: sibling)
        return zone
    }

    private func attachZoneGestures(
        to zone: UIView,
        doubleTapAction: Selector,
        controlsView: VideoControlsView,
        coordinator: Coordinator,
        requiring singleTap: UITapGestureRecognizer
    ) {
        let doubleTap = UITapGestureRecognizer(target: controlsView, action: doubleTapAction)
        doubleTap.numberOfTapsRequired = 2
        // Without this a double tap also fires the single-tap play/pause.
        doubleTap.require(toFail: singleTap)
        zone.addGestureRecognizer(doubleTap)

        let hold = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        hold.minimumPressDuration = 0.2
        hold.allowableMovement = 20
        hold.require(toFail: doubleTap)
        zone.addGestureRecognizer(hold)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        private let player: Binding<AVPlayer?>
        weak var controlsView: VideoControlsView?
        weak var playerViewController: AVPlayerViewController?

        // `nonisolated(unsafe)` so `deinit` — which is never actor-isolated — can
        // still remove the observer. Only ever touched on the main actor otherwise.
        nonisolated(unsafe) private var loopObserver: NSObjectProtocol?
        private var wasPlayingBeforeBoost = false
        private var rateBeforeBoost: Float = 1.0

        init(player: Binding<AVPlayer?>) {
            self.player = player
        }

        deinit {
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        }

        func observeLoop(for item: AVPlayerItem, player: AVPlayer) {
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }

        func invalidate() {
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
                self.loopObserver = nil
            }
        }

        @objc func handleSingleTap() {
            guard let player = player.wrappedValue else { return }
            player.rate == 0 ? player.play() : player.pause()
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let player = player.wrappedValue else { return }

            switch gesture.state {
            case .began:
                wasPlayingBeforeBoost = player.rate > 0
                rateBeforeBoost = wasPlayingBeforeBoost ? player.rate : 1.0
                if !wasPlayingBeforeBoost { player.play() }
                player.rate = 2.0
                controlsView?.setSpeedBoostActive(true)
            case .ended, .cancelled, .failed:
                if wasPlayingBeforeBoost {
                    player.rate = rateBeforeBoost
                } else {
                    player.pause()
                }
                controlsView?.setSpeedBoostActive(false)
            default:
                break
            }
        }
    }
}
