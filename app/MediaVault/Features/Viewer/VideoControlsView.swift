import AVFoundation
import UIKit

/// Scrubber, elapsed-time readout, and the transient skip / speed-boost indicators
/// for `EnhancedVideoPlayerView`.
final class VideoControlsView: UIView {

    private static let skipIndicatorSize = CGSize(width: 120, height: 60)
    private static let skipIndicatorOffsetX: CGFloat = 100
    private static let skipIndicatorOffsetY: CGFloat = -50
    private static let sliderHeight: CGFloat = 44
    private static let progressUpdateInterval = CMTime(seconds: 0.1, preferredTimescale: 10)

    private let player: AVPlayer
    private let skipDuration: Double

    private let progressSlider = UISlider()
    private let timeLabel = UILabel()
    private var speedIndicatorLabel: UILabel?

    // `nonisolated(unsafe)`: `deinit` is never actor-isolated, and the observer
    // token is opaque `Any?`, which the compiler cannot prove Sendable.
    nonisolated(unsafe) private var timeObserver: Any?
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false

    init(player: AVPlayer, skipDuration: Double) {
        self.player = player
        self.skipDuration = skipDuration
        super.init(frame: .zero)
        setUpViews()
        startTimeObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        speedIndicatorLabel?.removeFromSuperview()
    }

    // MARK: - Setup

    private func setUpViews() {
        backgroundColor = UIColor.black.withAlphaComponent(0.2)
        layer.cornerRadius = 8

        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressSlider.thumbTintColor = .white
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchBegan), for: .touchDown)
        progressSlider.addTarget(
            self,
            action: #selector(sliderTouchEnded),
            for: [.touchUpInside, .touchUpOutside]
        )
        addSubview(progressSlider)

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
            progressSlider.heightAnchor.constraint(equalToConstant: Self.sliderHeight),

            timeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 4),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            timeLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    // MARK: - Scrubbing

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
        let target = duration * Double(slider.value)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        timeLabel.text = " \(Self.formatTime(target)) / \(Self.formatTime(duration)) "
    }

    // MARK: - Skip zones

    @objc func leftDoubleTapped() {
        seek(by: -skipDuration)
        showSkipIndicator(forward: false)
    }

    @objc func rightDoubleTapped() {
        seek(by: skipDuration)
        showSkipIndicator(forward: true)
    }

    private func seek(by offset: Double) {
        let target = CMTimeAdd(
            player.currentTime(),
            CMTime(seconds: offset, preferredTimescale: 600)
        )
        player.seek(to: target)
    }

    private func showSkipIndicator(forward: Bool) {
        guard let container = superview else { return }

        let label = makeIndicatorLabel(
            text: forward ? " +\(Int(skipDuration))s " : " -\(Int(skipDuration))s ",
            fontSize: 32,
            weight: .heavy
        )
        label.layer.borderWidth = 2
        label.layer.borderColor = UIColor.white.cgColor
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(
                equalTo: container.centerXAnchor,
                constant: forward ? Self.skipIndicatorOffsetX : -Self.skipIndicatorOffsetX
            ),
            label.centerYAnchor.constraint(
                equalTo: container.centerYAnchor,
                constant: Self.skipIndicatorOffsetY
            ),
            label.widthAnchor.constraint(equalToConstant: Self.skipIndicatorSize.width),
            label.heightAnchor.constraint(equalToConstant: Self.skipIndicatorSize.height)
        ])

        UIView.animate(withDuration: 0.3, delay: 0.5, options: .curveEaseOut) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    // MARK: - Speed boost

    func setSpeedBoostActive(_ isActive: Bool) {
        guard let container = superview else { return }

        if isActive {
            guard speedIndicatorLabel == nil else { return }

            let label = makeIndicatorLabel(text: " 2× ", fontSize: 14, weight: .semibold)
            label.alpha = 0
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(
                    equalTo: container.safeAreaLayoutGuide.topAnchor,
                    constant: 12
                ),
                label.trailingAnchor.constraint(
                    equalTo: container.safeAreaLayoutGuide.trailingAnchor,
                    constant: -12
                )
            ])
            speedIndicatorLabel = label
            UIView.animate(withDuration: 0.15) { label.alpha = 1 }
        } else if let label = speedIndicatorLabel {
            speedIndicatorLabel = nil
            UIView.animate(withDuration: 0.2) {
                label.alpha = 0
            } completion: { _ in
                label.removeFromSuperview()
            }
        }
    }

    private func makeIndicatorLabel(
        text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: fontSize, weight: weight)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 8
        label.textAlignment = .center
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Progress

    private func startTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: Self.progressUpdateInterval,
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            guard let duration = self.player.currentItem?.duration.seconds,
                  duration.isFinite, duration > 0
            else { return }

            self.progressSlider.value = Float(time.seconds / duration)
            self.timeLabel.text =
                " \(Self.formatTime(time.seconds)) / \(Self.formatTime(duration)) "
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
