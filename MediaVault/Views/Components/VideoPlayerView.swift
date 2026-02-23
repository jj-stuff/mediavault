// ============================================================================
// VideoPlayerView.swift
// Contains two players — pick the right one for the context:
//   • EnhancedVideoPlayerView  → full-screen detail / FullScreenMediaView
//   • FeedVideoPlayerView      → FYP feed items / ForYouTab
// ============================================================================

import SwiftUI
import AVKit

// MARK: - EnhancedVideoPlayerView (Detail / Fullscreen Player)

struct EnhancedVideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var player: AVPlayer?
    let skipDuration: Double
    @Binding var isLandscape: Bool
    let shouldPlay: Bool
    let onPlayerReady: (() -> Void)?

    init(
        url: URL,
        player: Binding<AVPlayer?>,
        skipDuration: Double,
        isLandscape: Binding<Bool>,
        shouldPlay: Bool = false,
        onPlayerReady: (() -> Void)? = nil
    ) {
        self.url = url
        _player = player
        self.skipDuration = skipDuration
        _isLandscape = isLandscape
        self.shouldPlay = shouldPlay
        self.onPlayerReady = onPlayerReady
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = .black

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 5

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 1.0

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

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        playerViewController.view.addGestureRecognizer(singleTap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.2
        longPress.allowableMovement = 20
        playerViewController.view.addGestureRecognizer(longPress)

        let controlsView = VideoControlsView(player: player, skipDuration: skipDuration)
        controlsView.isHidden = isLandscape
        container.view.addSubview(controlsView)
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor, constant: -60),
            controlsView.heightAnchor.constraint(equalToConstant: 70)
        ])

        context.coordinator.controlsView = controlsView
        context.coordinator.playerViewController = playerViewController

        let leftDoubleTap = UITapGestureRecognizer(target: controlsView, action: #selector(VideoControlsView.leftDoubleTapped))
        leftDoubleTap.numberOfTapsRequired = 2
        leftDoubleTap.require(toFail: singleTap)

        let rightDoubleTap = UITapGestureRecognizer(target: controlsView, action: #selector(VideoControlsView.rightDoubleTapped))
        rightDoubleTap.numberOfTapsRequired = 2
        rightDoubleTap.require(toFail: singleTap)

        let leftTapView = UIView()
        leftTapView.translatesAutoresizingMaskIntoConstraints = false
        leftTapView.backgroundColor = .clear
        container.view.insertSubview(leftTapView, belowSubview: controlsView)

        let rightTapView = UIView()
        rightTapView.translatesAutoresizingMaskIntoConstraints = false
        rightTapView.backgroundColor = .clear
        container.view.insertSubview(rightTapView, belowSubview: controlsView)

        NSLayoutConstraint.activate([
            leftTapView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            leftTapView.topAnchor.constraint(equalTo: container.view.topAnchor),
            leftTapView.bottomAnchor.constraint(equalTo: controlsView.topAnchor, constant: -8),
            leftTapView.widthAnchor.constraint(equalTo: container.view.widthAnchor, multiplier: 0.3),

            rightTapView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            rightTapView.topAnchor.constraint(equalTo: container.view.topAnchor),
            rightTapView.bottomAnchor.constraint(equalTo: controlsView.topAnchor, constant: -8),
            rightTapView.widthAnchor.constraint(equalTo: container.view.widthAnchor, multiplier: 0.3)
        ])

        leftTapView.addGestureRecognizer(leftDoubleTap)
        rightTapView.addGestureRecognizer(rightDoubleTap)

        let leftHold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        leftHold.minimumPressDuration = longPress.minimumPressDuration
        leftHold.allowableMovement = longPress.allowableMovement
        leftHold.require(toFail: leftDoubleTap)
        leftTapView.addGestureRecognizer(leftHold)

        let rightHold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        rightHold.minimumPressDuration = longPress.minimumPressDuration
        rightHold.allowableMovement = longPress.allowableMovement
        rightHold.require(toFail: rightDoubleTap)
        rightTapView.addGestureRecognizer(rightHold)

        let loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        context.coordinator.loopObserver = loopObserver

        DispatchQueue.main.async {
            self.player = player
            self.onPlayerReady?()
            if self.shouldPlay { player.play() }
        }

        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let vc = context.coordinator.playerViewController {
            vc.videoGravity = isLandscape ? .resizeAspectFill : .resizeAspect
        }
        context.coordinator.controlsView?.isHidden = isLandscape
        if shouldPlay { player?.play() } else { player?.pause() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: $player) }

    // MARK: Coordinator

    final class Coordinator: NSObject {
        var player: Binding<AVPlayer?>
        weak var controlsView: VideoControlsView?
        weak var playerViewController: AVPlayerViewController?
        nonisolated(unsafe) var loopObserver: Any?

        init(player: Binding<AVPlayer?>) { self.player = player }

        deinit {
            if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
        }

        @objc func handleSingleTap() {
            guard let p = player.wrappedValue else { return }
            p.rate == 0 ? p.play() : p.pause()
        }

        private var wasPlayingBeforeBoost = false
        private var originalRate: Float = 1.0

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let p = player.wrappedValue else { return }
            switch gesture.state {
            case .began:
                wasPlayingBeforeBoost = p.rate > 0
                originalRate = wasPlayingBeforeBoost ? p.rate : 1.0
                if !wasPlayingBeforeBoost { p.play() }
                p.rate = 2.0
                controlsView?.setSpeedBoostActive(true)
            case .ended, .cancelled, .failed:
                wasPlayingBeforeBoost ? (p.rate = originalRate) : p.pause()
                controlsView?.setSpeedBoostActive(false)
            default: break
            }
        }
    }
}

// MARK: - VideoControlsView (scrubber + double-tap skip + speed indicator)

final class VideoControlsView: UIView {
    let player: AVPlayer
    private let skipDuration: Double
    private var progressSlider: UISlider!
    private var timeLabel: UILabel!
    private nonisolated(unsafe) var timeObserver: Any?
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false
    private var speedIndicatorLabel: UILabel?

    init(player: AVPlayer, skipDuration: Double) {
        self.player = player
        self.skipDuration = skipDuration
        super.init(frame: .zero)
        setupUI()
        startTimeObserver()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        speedIndicatorLabel?.removeFromSuperview()
    }

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.2)
        layer.cornerRadius = 8

        progressSlider = UISlider()
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressSlider.thumbTintColor = .white
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchBegan), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderTouchEnded), for: [.touchUpInside, .touchUpOutside])
        addSubview(progressSlider)

        timeLabel = UILabel()
        timeLabel.textColor = .white
        timeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timeLabel.text = " 0:00 / 0:00 "
        timeLabel.textAlignment = .center
        timeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        timeLabel.layer.cornerRadius = 4
        timeLabel.clipsToBounds = true
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            progressSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressSlider.topAnchor.constraint(equalTo: topAnchor),
            progressSlider.heightAnchor.constraint(equalToConstant: 44),

            timeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 4),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            timeLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    @objc private func sliderTouchBegan() {
        isScrubbing = true
        wasPlayingBeforeScrub = player.rate > 0
        player.pause()
    }

    @objc private func sliderTouchEnded() {
        isScrubbing = false
        if wasPlayingBeforeScrub { player.play() }
    }

    @objc private func sliderValueChanged(_ slider: UISlider) {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite else { return }
        let time = duration * Double(slider.value)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        timeLabel.text = " \(formatTime(time)) / \(formatTime(duration)) "
    }

    @objc func leftDoubleTapped() {
        let newTime = CMTimeSubtract(player.currentTime(), CMTime(seconds: skipDuration, preferredTimescale: 600))
        player.seek(to: newTime)
        showSkipIndicator(forward: false)
    }

    @objc func rightDoubleTapped() {
        let newTime = CMTimeAdd(player.currentTime(), CMTime(seconds: skipDuration, preferredTimescale: 600))
        player.seek(to: newTime)
        showSkipIndicator(forward: true)
    }

    private func showSkipIndicator(forward: Bool) {
        guard let sv = superview else { return }
        let label = UILabel()
        label.text = forward ? " +\(Int(skipDuration))s " : " -\(Int(skipDuration))s "
        label.textColor = .white
        label.font = .systemFont(ofSize: 32, weight: .heavy)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.textAlignment = .center
        label.layer.borderWidth = 2
        label.layer.borderColor = UIColor.white.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: sv.centerXAnchor, constant: forward ? 100 : -100),
            label.centerYAnchor.constraint(equalTo: sv.centerYAnchor, constant: -50),
            label.widthAnchor.constraint(equalToConstant: 120),
            label.heightAnchor.constraint(equalToConstant: 60)
        ])
        UIView.animate(withDuration: 0.3, delay: 0.5, options: .curveEaseOut) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    func setSpeedBoostActive(_ isActive: Bool) {
        guard let sv = superview else { return }
        if isActive {
            guard speedIndicatorLabel == nil else { return }
            let label = UILabel()
            label.text = " 2× "
            label.textColor = .white
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 6
            label.textAlignment = .center
            label.clipsToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alpha = 0
            sv.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: sv.safeAreaLayoutGuide.topAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: sv.safeAreaLayoutGuide.trailingAnchor, constant: -12)
            ])
            speedIndicatorLabel = label
            UIView.animate(withDuration: 0.15) { label.alpha = 1 }
        } else if let label = speedIndicatorLabel {
            speedIndicatorLabel = nil
            UIView.animate(withDuration: 0.2, animations: { label.alpha = 0 }) { _ in label.removeFromSuperview() }
        }
    }

    private func startTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            let current = time.seconds
            let duration = self.player.currentItem?.duration.seconds ?? 0
            guard duration.isFinite && duration > 0 else { return }
            self.progressSlider.value = Float(current / duration)
            self.timeLabel.text = " \(self.formatTime(current)) / \(self.formatTime(duration)) "
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

// MARK: - FeedVideoPlayerView (Lightweight FYP Player)

struct FeedVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    let shouldPlay: Bool
    let videoGravity: AVLayerVideoGravity

    init(player: AVPlayer, shouldPlay: Bool = true, videoGravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.player = player
        self.shouldPlay = shouldPlay
        self.videoGravity = videoGravity
    }

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeUIView(context: Context) -> FeedPlayerUIView {
        let view = FeedPlayerUIView(player: player)
        view.playerLayer.videoGravity = videoGravity

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        view.addGestureRecognizer(tap)

        let loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in player?.seek(to: .zero); player?.play() }
        context.coordinator.loopObserver = loopObserver

        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        let timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak view, weak player] time in
            guard let view, let player,
                  let duration = player.currentItem?.duration.seconds,
                  duration.isFinite && duration > 0 else { return }
            view.progressBar.progress = Float(time.seconds / duration)
        }
        context.coordinator.timeObserver = timeObserver

        return view
    }

    func updateUIView(_ uiView: FeedPlayerUIView, context: Context) {
        uiView.playerLayer.videoGravity = videoGravity
        shouldPlay ? player.play() : player.pause()
    }

    final class Coordinator: NSObject {
        let player: AVPlayer
        nonisolated(unsafe) var loopObserver: Any?
        nonisolated(unsafe) var timeObserver: Any?

        init(player: AVPlayer) { self.player = player }

        deinit {
            if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = timeObserver { player.removeTimeObserver(obs) }
        }

        @objc func handleTap() {
            player.rate == 0 ? player.play() : player.pause()
        }
    }
}

// MARK: - FeedPlayerUIView

final class FeedPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

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

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
