import Foundation

/// Favourites, persisted as paths relative to the library root.
///
/// Source folders stay read-only — nothing is written into the user's library, so
/// likes work the same on a read-only external drive or a remote server.
@Observable
final class LikesService {
    private(set) var likedItems: [LikedItem] = []

    private let store: KeyValueStore

    init(store: KeyValueStore) {
        self.store = store
        loadLikes()
    }

    // MARK: - Queries

    func isLiked(mediaItem: MediaItem, rootURL: URL) -> Bool {
        index(of: mediaItem, rootURL: rootURL) != nil
    }

    // MARK: - Mutations

    func toggleLike(mediaItem: MediaItem, rootURL: URL) {
        if let index = index(of: mediaItem, rootURL: rootURL) {
            likedItems.remove(at: index)
        } else {
            likedItems.insert(LikedItem(from: mediaItem, rootURL: rootURL), at: 0)
        }
        saveLikes()
    }

    func unlike(item: LikedItem) {
        likedItems.removeAll { $0.id == item.id }
        saveLikes()
    }

    /// Removes any like pointing at `mediaItem`. No-op when it was never liked.
    ///
    /// Called after a delete: without it the like survives its file and resolves to
    /// a path that no longer exists, showing a permanently broken cell in Liked.
    func unlike(mediaItem: MediaItem, rootURL: URL) {
        guard let index = index(of: mediaItem, rootURL: rootURL) else { return }
        likedItems.remove(at: index)
        saveLikes()
    }

    func clearAll() {
        likedItems.removeAll()
        saveLikes()
    }

    // MARK: - Storage

    private func index(of mediaItem: MediaItem, rootURL: URL) -> Int? {
        let path = MediaPath.relative(for: mediaItem.url, under: rootURL)
        return likedItems.firstIndex { MediaPath.normalize($0.relativePath) == path }
    }

    private func saveLikes() {
        guard let data = try? JSONEncoder().encode(likedItems) else { return }
        store.write(data, forKey: StorageKey.likedItems)
    }

    private func loadLikes() {
        guard let data = store.data(forKey: StorageKey.likedItems),
              let items = try? JSONDecoder().decode([LikedItem].self, from: data)
        else { return }
        likedItems = items
    }
}
