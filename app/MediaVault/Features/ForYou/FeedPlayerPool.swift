import AVFoundation

/// Keeps a small window of `AVPlayer`s warm around the item on screen.
///
/// SwiftUI's lazy stacks do not recycle rows the way `UITableView` recycles cells —
/// a row is destroyed when it scrolls away and rebuilt from scratch when it comes
/// back. Left alone, that means every swipe creates an `AVPlayer`, waits for it to
/// buffer, and only then shows a frame, which is the stutter you feel at the top of
/// each new video.
///
/// So playback state is deliberately held *outside* the view tree, here. The pool
/// builds players for the next couple of items before the user reaches them and
/// tears down the ones they have scrolled past. This is the equivalent of cell
/// reuse for this screen; hand-rolling `prepareForReuse`-style recycling of the
/// views themselves would fight SwiftUI and buy nothing.
@Observable
final class FeedPlayerPool {

    /// Hard cap on live players. iOS only supports a limited number of simultaneous
    /// video render pipelines, and exceeding it makes players silently fail to
    /// produce frames. The window is 4 wide, so this leaves headroom.
    private static let maxPlayers = 6

    /// Seconds of video to buffer ahead. Small enough to start fast, large enough
    /// to survive a slow first read from a NAS.
    private static let forwardBuffer: TimeInterval = 5

    private var players: [UUID: AVPlayer] = [:]
    private var loopObservers: [UUID: NSObjectProtocol] = [:]
    private var activeID: UUID?

    // No `deinit` teardown: the pool is owned by the composition root and lives as
    // long as the app, so it would never run. Observers are removed in `release`,
    // which every eviction path goes through.

    /// The player for `item`, if the pool is holding one.
    func player(for item: MediaItem) -> AVPlayer? {
        players[item.id]
    }

    /// Brings the pool in line with the current scroll position.
    ///
    /// Creates players for videos in `window`, discards any outside it, and makes
    /// `activeID` the only one playing.
    func update(window: ArraySlice<MediaItem>, activeID: UUID?) {
        let videos = window.filter { $0.mediaType == .video }
        let wanted = Set(videos.map(\.id))

        for id in players.keys where !wanted.contains(id) {
            release(id)
        }

        for item in videos.prefix(Self.maxPlayers) where players[item.id] == nil {
            players[item.id] = makePlayer(for: item)
        }

        setActive(activeID)
    }

    /// Plays the active item and pauses everything else.
    ///
    /// The non-active players stay alive and buffered — that is the entire point of
    /// the pool — they are simply not running.
    func setActive(_ id: UUID?) {
        // Only restart from the top when the active item actually changes. `update`
        // runs on every scroll adjustment, and seeking on each one would keep
        // yanking the current video back to zero.
        let changed = activeID != id
        activeID = id

        for (playerID, player) in players {
            guard playerID == id else {
                player.pause()
                continue
            }
            if changed { player.seek(to: .zero) }
            if player.rate == 0 { player.play() }
        }
    }

    /// Pauses everything without tearing the pool down, for when the feed goes
    /// off screen but the user is likely to come straight back to it.
    func pauseAll() {
        activeID = nil
        for player in players.values { player.pause() }
    }

    func releaseAll() {
        for id in players.keys { release(id) }
        activeID = nil
    }

    // MARK: - Lifecycle

    private func makePlayer(for item: MediaItem) -> AVPlayer {
        let playerItem = AVPlayerItem(url: item.url)
        playerItem.preferredForwardBufferDuration = Self.forwardBuffer

        let player = AVPlayer(playerItem: playerItem)
        // Start on whatever is buffered rather than holding the first frame back
        // waiting for a stall-free estimate.
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none

        loopObservers[item.id] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        return player
    }

    private func release(_ id: UUID) {
        players[id]?.pause()
        players[id]?.replaceCurrentItem(with: nil)
        players.removeValue(forKey: id)

        if let observer = loopObservers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
