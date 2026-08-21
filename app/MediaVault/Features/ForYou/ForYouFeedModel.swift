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

    /// Slots, not files — see `FeedEntry` for why the distinction matters.
    private(set) var entries: [FeedEntry] = []

    /// Identity of the profile set the current feed was generated from, so a rescan
    /// that produces genuinely different content rebuilds the feed, while an
    /// unrelated update leaves the user's scroll position alone.
    private var generatedFrom: Set<UUID> = []

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Building

    /// Builds the feed if it is missing or was generated from a different library.
    func buildIfNeeded(from profiles: [MediaProfile]) {
        let identity = Set(profiles.map(\.id))
        guard !profiles.isEmpty, entries.isEmpty || identity != generatedFrom else { return }
        rebuild(from: profiles)
    }

    func rebuild(from profiles: [MediaProfile]) {
        entries = ForYouAlgorithm.generateFeed(from: profiles).map(FeedEntry.init)
        generatedFrom = Set(profiles.map(\.id))
        AppLog.feed.info(
            "rebuilt: \(self.entries.count) slots from \(profiles.count) profiles"
        )
    }

    func reset() {
        entries = []
        generatedFrom = []
    }

    // MARK: - Pagination

    func loadMoreIfNeeded(reachedIndex index: Int, profiles: [MediaProfile]) {
        guard !profiles.isEmpty,
              index >= entries.count - Self.prefetchThreshold
        else { return }

        let batch = ForYouAlgorithm.generateNextBatch(
            from: profiles,
            currentFeed: entries.map(\.item)
        )
        guard !batch.isEmpty else { return }

        entries.append(contentsOf: batch.map(FeedEntry.init))
        AppLog.feed.debug(
            "appended \(batch.count) slots at index \(index), now \(self.entries.count)"
        )
    }

    // MARK: - Mutation

    /// Drops every slot showing the file `itemID`.
    ///
    /// Plural on purpose. A repeated feed can hold the same file several slots
    /// apart, and removing only the one the user was looking at left the others
    /// pointing at a file that no longer exists.
    func removeItem(id itemID: UUID) {
        let before = entries.count
        entries.removeAll { $0.item.id == itemID }
        AppLog.feed.info("removed \(before - self.entries.count) slots for a deleted file")
    }

    // MARK: - Windowing

    func index(of entryID: UUID) -> Int? {
        entries.firstIndex { $0.id == entryID }
    }

    /// The slice of the feed worth having players ready for: the current slot, the
    /// one behind it, and the next two ahead.
    func preloadWindow(around entryID: UUID?) -> ArraySlice<FeedEntry> {
        guard let entryID, let index = index(of: entryID) else { return entries.prefix(2) }
        let lower = max(entries.startIndex, index - 1)
        let upper = min(entries.endIndex, index + 3)
        return entries[lower..<upper]
    }
}
