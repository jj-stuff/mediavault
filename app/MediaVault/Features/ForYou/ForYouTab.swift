import SwiftUI

struct ForYouTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(ForYouFeedModel.self) private var feed
    @Environment(FeedPlayerPool.self) private var playerPool
    @Environment(OrientationController.self) private var orientation

    /// Identity of the item filling the screen. Driven by `scrollPosition`, and the
    /// single input to both pagination and player preloading.
    @State private var currentItemID: UUID?

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
        }
        .onAppear { build() }
        .onChange(of: scanner.profiles) { build() }
        .onChange(of: currentItemID) { _, newID in advance(to: newID) }
        .onDisappear {
            // Kept alive rather than torn down: the user is one tab away and the
            // buffered players are exactly what makes coming back feel instant.
            playerPool.pauseAll()
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
                ForEach(feed.items) { item in
                    FeedItemView(item: item, isActive: item.id == currentItemID)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $currentItemID)
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
    }

    // MARK: - Feed lifecycle

    private func build() {
        feed.buildIfNeeded(from: scanner.profiles)
        if currentItemID == nil { currentItemID = feed.items.first?.id }
        advance(to: currentItemID)
    }

    /// Extends the feed and re-aims the player pool at the new position.
    ///
    /// Doing both here — rather than in each row's `onAppear` — means they are
    /// driven by where the user actually is, not by which rows SwiftUI happens to
    /// have instantiated.
    private func advance(to id: UUID?) {
        guard let id, let index = feed.index(of: id) else { return }
        feed.loadMoreIfNeeded(reachedIndex: index, profiles: scanner.profiles)
        playerPool.update(window: feed.preloadWindow(around: id), activeID: id)
    }
}
