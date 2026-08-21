import SwiftUI

struct ForYouTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(ForYouFeedModel.self) private var feed
    @Environment(FeedPlayerPool.self) private var playerPool
    @Environment(OrientationController.self) private var orientation
    @Environment(LibraryController.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    /// Identity of the *slot* filling the screen — see `FeedEntry`. Driven by
    /// `scrollPosition`, and the single input to pagination and player preloading.
    @State private var currentEntryID: UUID?

    /// How far the feed has been dragged past its own top edge, and whether a
    /// refresh started by that drag is still running.
    @State private var pullDistance: CGFloat = 0
    @State private var isRefreshing = false

    /// Drag past the top needed to fire a refresh.
    private static let refreshThreshold: CGFloat = 90

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if scanner.profiles.isEmpty {
                emptyState
            } else if feed.isEmpty {
                ProgressView("Building your feed…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                feedView
            }

            refreshIndicator
        }
        .onAppear {
            build()
            playerPool.resume()
        }
        .onChange(of: scanner.profiles) { build() }
        .onChange(of: currentEntryID) { _, newID in advance(to: newID) }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding must not leave a video playing behind the lock screen,
            // and coming back must not restart it from zero.
            phase == .active ? playerPool.resume() : playerPool.suspend()
        }
        .onDisappear {
            // Kept alive rather than torn down: the user is one tab away and the
            // buffered players are exactly what makes coming back feel instant.
            playerPool.suspend()
            orientation.restorePortrait()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Content", systemImage: "play.square.stack")
        } description: {
            Text("Select a folder in Settings to start discovering content.")
        }
        .foregroundStyle(.white)
    }

    private var feedView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(feed.entries) { entry in
                    FeedItemView(entry: entry, isActive: entry.id == currentEntryID)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $currentEntryID)
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        // `.refreshable` belongs to a different gesture world than a paging scroll
        // view, so the pull is measured directly. Bouncing past the top only happens
        // on the first slot, which is also the only place a reshuffle makes sense.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            -(geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, distance in
            pullDistance = max(0, distance)
            if pullDistance > Self.refreshThreshold { refreshIfPulledFromTop() }
        }
    }

    /// Spinner that fades in with the pull and spins for real once it fires.
    @ViewBuilder
    private var refreshIndicator: some View {
        let progress = min(1, pullDistance / Self.refreshThreshold)
        if isRefreshing || progress > 0.05 {
            VStack {
                ProgressView()
                    .tint(.white)
                    .padding(14)
                    .background(.ultraThinMaterial, in: .circle)
                    .scaleEffect(isRefreshing ? 1 : 0.7 + 0.3 * progress)
                    .opacity(isRefreshing ? 1 : Double(progress))
                    .padding(.top, ScreenInsets.top + 8)
                Spacer()
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    // MARK: - Feed lifecycle

    private func build() {
        feed.buildIfNeeded(from: scanner.profiles)

        // A rescan replaces every slot, so a remembered id can point at something
        // that no longer exists. Left alone, `scrollPosition` had no anchor at all —
        // which is its own contribution to the feed refusing to settle on a page.
        let stillPresent = currentEntryID.flatMap { feed.index(of: $0) } != nil
        if !stillPresent { currentEntryID = feed.entries.first?.id }

        advance(to: currentEntryID)
    }

    /// Extends the feed and re-aims the player pool at the new position.
    ///
    /// Doing both here — rather than in each row's `onAppear` — means they are
    /// driven by where the user actually is, not by which rows SwiftUI happens to
    /// have instantiated.
    private func advance(to id: UUID?) {
        guard let id, let index = feed.index(of: id) else {
            playerPool.setActive(nil)
            return
        }
        AppLog.feed.debug("position -> slot \(index) (\(id.short, privacy: .public))")
        feed.loadMoreIfNeeded(reachedIndex: index, profiles: scanner.profiles)
        playerPool.update(window: feed.preloadWindow(around: id), activeID: id)
    }

    // MARK: - Refresh

    private func refreshIfPulledFromTop() {
        guard !isRefreshing, currentEntryID == feed.entries.first?.id else { return }
        Task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        AppLog.feed.info("pull to refresh")

        playerPool.suspend()
        playerPool.releaseAll()

        await library.refresh()
        feed.rebuild(from: scanner.profiles)

        currentEntryID = feed.entries.first?.id
        playerPool.resume()
        advance(to: currentEntryID)

        isRefreshing = false
        pullDistance = 0
    }
}
