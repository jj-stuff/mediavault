import SwiftUI
import AVKit

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

        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 1.0
        player.currentItem?.preferredForwardBufferDuration = 5

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
        container.view.addSubview(leftTapView)

        let rightTapView = UIView()
        rightTapView.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(rightTapView)

        NSLayoutConstraint.activate([
            leftTapView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            leftTapView.topAnchor.constraint(equalTo: container.view.topAnchor),
            leftTapView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            leftTapView.widthAnchor.constraint(equalTo: container.view.widthAnchor, multiplier: 0.3),

            rightTapView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            rightTapView.topAnchor.constraint(equalTo: container.view.topAnchor),
            rightTapView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            rightTapView.widthAnchor.constraint(equalTo: container.view.widthAnchor, multiplier: 0.3)
        ])

        leftTapView.addGestureRecognizer(leftDoubleTap)
        rightTapView.addGestureRecognizer(rightDoubleTap)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }

        DispatchQueue.main.async {
            self.player = player
            self.onPlayerReady?()
            if self.shouldPlay {
                player.play()
            }
        }

        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let playerViewController = context.coordinator.playerViewController {
            playerViewController.videoGravity = isLandscape ? .resizeAspectFill : .resizeAspect
        }
        context.coordinator.controlsView?.isHidden = isLandscape

        if shouldPlay {
            player?.play()
        } else {
            player?.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(player: $player)
    }

    class Coordinator: NSObject {
        var player: Binding<AVPlayer?>
        weak var controlsView: VideoControlsView?
        weak var playerViewController: AVPlayerViewController?

        init(player: Binding<AVPlayer?>) {
            self.player = player
        }

        @objc func handleSingleTap() {
            guard let player = player.wrappedValue else { return }
            if player.rate == 0 {
                player.play()
            } else {
                player.pause()
            }
        }
    }
}

final class VideoControlsView: UIView {
    let player: AVPlayer
    private let skipDuration: Double
    private var progressSlider: UISlider!
    private var timeLabel: UILabel!
    private var timeObserver: Any?
    private var isScrubbing = false

    init(player: AVPlayer, skipDuration: Double) {
        self.player = player
        self.skipDuration = skipDuration
        super.init(frame: .zero)
        setupUI()
        startTimeObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.2)
        layer.cornerRadius = 8

        let sliderContainer = UIView()
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sliderContainer)

        progressSlider = UISlider()
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressSlider.thumbTintColor = .white
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchBegan), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderTouchEnded), for: [.touchUpInside, .touchUpOutside])
        sliderContainer.addSubview(progressSlider)

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
            sliderContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sliderContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            sliderContainer.topAnchor.constraint(equalTo: topAnchor),
            sliderContainer.heightAnchor.constraint(equalToConstant: 44),

            progressSlider.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -16),
            progressSlider.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor),

            timeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timeLabel.topAnchor.constraint(equalTo: sliderContainer.bottomAnchor, constant: 4),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            timeLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    @objc private func sliderTouchBegan() {
        isScrubbing = true
        player.pause()
    }

    @objc private func sliderTouchEnded() {
        isScrubbing = false
        player.play()
    }

    @objc private func sliderValueChanged(_ slider: UISlider) {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite else { return }
        let time = duration * Double(slider.value)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 1))
        timeLabel.text = " \(formatTime(time)) / \(formatTime(duration)) "
    }

    @objc func leftDoubleTapped() {
        let currentTime = player.currentTime()
        let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipDuration, preferredTimescale: 1))
        player.seek(to: newTime)
        showSkipIndicator(forward: false)
    }

    @objc func rightDoubleTapped() {
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipDuration, preferredTimescale: 1))
        player.seek(to: newTime)
        showSkipIndicator(forward: true)
    }

    private func showSkipIndicator(forward: Bool) {
        guard let superview else { return }

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

        superview.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: superview.centerXAnchor, constant: forward ? 100 : -100),
            label.centerYAnchor.constraint(equalTo: superview.centerYAnchor, constant: -50),
            label.widthAnchor.constraint(equalToConstant: 120),
            label.heightAnchor.constraint(equalToConstant: 60)
        ])

        UIView.animate(withDuration: 0.3, delay: 0.5, options: .curveEaseOut) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    private func startTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }

            let currentSeconds = time.seconds
            let duration = self.player.currentItem?.duration.seconds ?? 0

            if duration.isFinite && duration > 0 {
                self.progressSlider.value = Float(currentSeconds / duration)
                self.timeLabel.text = " \(self.formatTime(currentSeconds)) / \(self.formatTime(duration)) "
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
