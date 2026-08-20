import Foundation

/// Owns the For You feed: its contents, its pagination, and its removals.
///
/// This is the one screen with enough genuine state to justify a model of its own.
/// It used to live as `@State` smeared across `onAppear`, `onChange`, and a closure
/// passed down into each row.
@Observable
final class ForYouFeedModel {

    /// How close to the end the user has to get before the next batch is appended.
    private static let prefetchThreshold = 10

    private(set) var items: [MediaItem] = []

    /// Identity of the profile set the current feed was generated from, so a rescan
    /// that produces genuinely different content rebuilds the feed, while an
    /// unrelated update leaves the user's scroll position alone.
    private var generatedFrom: Set<UUID> = []

    var isEmpty: Bool { items.isEmpty }

    // MARK: - Building

    /// Builds the feed if it is missing or was generated from a different library.
    func buildIfNeeded(from profiles: [MediaProfile]) {
        let identity = Set(profiles.map(\.id))
        guard !profiles.isEmpty, items.isEmpty || identity != generatedFrom else { return }
        rebuild(from: profiles)
    }

    func rebuild(from profiles: [MediaProfile]) {
        items = ForYouAlgorithm.generateFeed(from: profiles)
        generatedFrom = Set(profiles.map(\.id))
    }

    func reset() {
        items = []
        generatedFrom = []
    }

    // MARK: - Pagination

    func loadMoreIfNeeded(reachedIndex index: Int, profiles: [MediaProfile]) {
        guard !profiles.isEmpty,
              index >= items.count - Self.prefetchThreshold
        else { return }

        items.append(contentsOf: ForYouAlgorithm.generateNextBatch(
            from: profiles,
            currentFeed: items
        ))
    }

    // MARK: - Mutation

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    // MARK: - Windowing

    func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// The slice of the feed worth having players ready for: the current item, the
    /// one behind it, and the next two ahead.
    func preloadWindow(around id: UUID?) -> ArraySlice<MediaItem> {
        guard let id, let index = index(of: id) else { return items.prefix(2) }
        let lower = max(items.startIndex, index - 1)
        let upper = min(items.endIndex, index + 3)
        return items[lower..<upper]
    }
}
