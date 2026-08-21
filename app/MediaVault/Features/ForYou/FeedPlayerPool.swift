import AVFoundation

/// Keeps a small window of `AVPlayer`s warm around the slot on screen.
///
/// SwiftUI's lazy stacks do not recycle rows the way `UITableView` recycles cells —
/// a row is destroyed when it scrolls away and rebuilt from scratch when it comes
/// back. Left alone, that means every swipe creates an `AVPlayer`, waits for it to
/// buffer, and only then shows a frame, which is the stutter you feel at the top of
/// each new video.
///
/// So playback state is deliberately held *outside* the view tree, here. The pool
/// builds players for the next couple of slots before the user reaches them and
/// tears down the ones they have scrolled past. This is the equivalent of cell
/// reuse for this screen; hand-rolling `prepareForReuse`-style recycling of the
/// views themselves would fight SwiftUI and buy nothing.
///
/// Everything is keyed on `FeedEntry.id`, the slot, never on `MediaItem.id`, the
/// file. A repeated feed shows the same file in several slots, and keying on the
/// file collapsed them onto one player — two rows driving one `AVPlayer`, and a
/// scroll to a later repeat resolving back to the first one.
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

    private(set) var activeID: UUID?

    /// True while the feed is covered or off screen. Distinct from "nothing is
    /// active": the pool still remembers which slot the user is on, so coming back
    /// resumes mid-video instead of restarting it.
    private(set) var isSuspended = false

    // No `deinit` teardown: the pool is owned by the composition root and lives as
    // long as the app, so it would never run. Observers are removed in `release`,
    // which every eviction path goes through.

    /// The player for `entry`, if the pool is holding one.
    func player(for entry: FeedEntry) -> AVPlayer? {
        players[entry.id]
    }

    /// Brings the pool in line with the current scroll position.
    ///
    /// Creates players for videos in `window`, discards any outside it, and makes
    /// `activeID` the only one playing.
    func update(window: ArraySlice<FeedEntry>, activeID: UUID?) {
        let videos = window.filter { $0.item.mediaType == .video }
        let wanted = Set(videos.map(\.id))

        // `Array(...)` so the dictionary is not being mutated through the same
        // view that is being iterated.
        for id in Array(players.keys) where !wanted.contains(id) {
            release(id)
        }

        for entry in videos.prefix(Self.maxPlayers) where players[entry.id] == nil {
            players[entry.id] = makePlayer(for: entry)
            AppLog.playback.debug(
                "created player \(entry.id.short, privacy: .public) for \(entry.item.fileName, privacy: .public)"
            )
        }

        setActive(activeID)
    }

    /// Plays the active slot and pauses everything else.
    ///
    /// The non-active players stay alive and buffered — that is the entire point of
    /// the pool — they are simply not running.
    func setActive(_ id: UUID?) {
        // Only restart from the top when the active slot actually changes. `update`
        // runs on every scroll adjustment, and seeking on each one would keep
        // yanking the current video back to zero.
        let changed = activeID != id
        activeID = id

        if changed {
            AppLog.playback.info(
                "active -> \(id?.short ?? "none", privacy: .public), \(self.players.count) players live"
            )
        }

        for (playerID, player) in players {
            guard playerID == id else {
                if player.rate != 0 {
                    // Should not happen: a second audible player is exactly the
                    // "double audio" symptom, so it is worth a line when it does.
                    AppLog.playback.error(
                        "paused a stray playing player \(playerID.short, privacy: .public)"
                    )
                }
                player.pause()
                continue
            }

            if changed { player.seek(to: .zero) }
            if isSuspended {
                player.pause()
            } else if player.rate == 0 {
                player.play()
            }
        }
    }

    /// Pauses everything without forgetting the position.
    ///
    /// Used whenever the feed stops being the thing in front of the user — another
    /// tab, a profile sheet on top of it, the app going to the background. The
    /// previous version cleared the active slot too, so coming back re-selected it
    /// as a *change* and restarted the video from zero.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for player in players.values { player.pause() }
        AppLog.playback.debug("suspended")
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        AppLog.playback.debug("resumed at \(self.activeID?.short ?? "none", privacy: .public)")
        guard let activeID, let player = players[activeID] else { return }
        player.play()
    }

    func releaseAll() {
        for id in Array(players.keys) { release(id) }
        activeID = nil
    }

    // MARK: - Lifecycle

    private func makePlayer(for entry: FeedEntry) -> AVPlayer {
        let playerItem = AVPlayerItem(url: entry.item.url)
        playerItem.preferredForwardBufferDuration = Self.forwardBuffer

        let player = AVPlayer(playerItem: playerItem)
        // Start on whatever is buffered rather than holding the first frame back
        // waiting for a stall-free estimate.
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none

        let entryID = entry.id
        loopObservers[entryID] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let player else { return }
                player.seek(to: .zero)
                // A player that reached the end while parked off screen must not
                // start making noise again just because it looped.
                guard let self, self.activeID == entryID, !self.isSuspended else { return }
                player.play()
            }
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
        AppLog.playback.debug("released player \(id.short, privacy: .public)")
    }
}
