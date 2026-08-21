import Foundation

/// One slot in the For You feed.
///
/// The feed repeats content on purpose: when a small library runs out, the next
/// batch is generated without exclusions so scrolling never dead-ends. That means
/// the same `MediaItem` — and therefore the same `MediaItem.id` — can occupy
/// several slots.
///
/// Identifying rows by `MediaItem.id` was the bug behind three separate symptoms.
/// `ForEach` had duplicate ids, so SwiftUI's paging lost its anchor and stopped
/// snapping; `scrollPosition` reported an id that `firstIndex(of:)` resolved back to
/// the *first* copy, so scrolling to slot 60 aimed the player pool at slot 3 and
/// played that video instead; and the pool keyed one `AVPlayer` to two visible rows.
///
/// So the slot gets its own identity. `item.id` still identifies the file — which is
/// what likes and deletes care about — and `id` identifies the position it is in.
nonisolated struct FeedEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let item: MediaItem

    init(item: MediaItem) {
        self.id = UUID()
        self.item = item
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: FeedEntry, rhs: FeedEntry) -> Bool { lhs.id == rhs.id }
}
