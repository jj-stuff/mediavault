import AVFoundation
import SwiftUI

/// Playback position for the feed: a thin bar that can also be dragged to scrub.
///
/// This used to be a `UIProgressView` pinned to the bottom edge of the player
/// layer. Because the feed ignores the safe area, "the bottom edge" was the very
/// bottom of the screen — underneath the tab bar and the home indicator, where it
/// could not be read and where the system's edge gesture claimed any touch before
/// it arrived. Living in the overlay instead puts it clear of both and lets it own
/// a real gesture.
///
/// Position is polled rather than observed. A periodic time observer has to be
/// removed from exactly the right `AVPlayer` at exactly the right moment, and the
/// pool hands the same view a different player as the feed shifts; a `.task` is
/// cancelled for us when the row goes away or the player changes.
struct FeedScrubBar: View {
    let player: AVPlayer

    private static let idleHeight: CGFloat = 3
    private static let activeHeight: CGFloat = 7
    private static let touchHeight: CGFloat = 32
    private static let tick = Duration.milliseconds(100)

    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var wasPlaying = false

    private var shown: Double { isScrubbing ? scrubProgress : progress }

    var body: some View {
        VStack(spacing: 6) {
            if isScrubbing {
                Text("\(Self.timestamp(shown * duration)) / \(Self.timestamp(duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule()
                        .fill(.white)
                        .frame(width: CGFloat(max(0, min(1, shown))) * width)
                }
                .frame(height: isScrubbing ? Self.activeHeight : Self.idleHeight)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(.rect)
                .highPriorityGesture(
                    // `minimumDistance: 0` so a tap jumps straight to that position;
                    // high priority so the paging scroll view does not swallow it.
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0, width > 0 else { return }
                            if !isScrubbing { beginScrub() }
                            scrubProgress = Double(min(1, max(0, value.location.x / width)))
                        }
                        .onEnded { _ in endScrub() }
                )
            }
            .frame(height: Self.touchHeight)
        }
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
        // Re-keyed when the pool swaps the player under this row, which cancels the
        // old poll rather than leaving two of them writing to the same bar.
        .task(id: ObjectIdentifier(player)) {
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    // MARK: - Position

    private func sample() {
        let seconds = player.currentItem?.duration.seconds ?? 0
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        guard !isScrubbing, duration > 0 else { return }
        progress = player.currentTime().seconds / duration
    }

    private func beginScrub() {
        isScrubbing = true
        wasPlaying = player.rate > 0
        scrubProgress = progress
        player.pause()
    }

    private func endScrub() {
        defer { isScrubbing = false }
        guard duration > 0 else { return }
        // Zero tolerance: a scrub that lands half a second away from where the
        // finger was feels broken, and these are short clips.
        player.seek(
            to: CMTime(seconds: scrubProgress * duration, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        progress = scrubProgress
        if wasPlaying { player.play() }
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
