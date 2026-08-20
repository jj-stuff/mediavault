import Foundation

/// Persists access to the user's chosen folder across launches.
///
/// A plain path is useless here: outside its own container the app can only read a
/// folder it was explicitly granted, and that grant is what a security-scoped
/// bookmark preserves.
@Observable
final class FolderBookmarkStore {
    private let store: KeyValueStore

    init(store: KeyValueStore) {
        self.store = store
    }

    func save(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        store.write(data, forKey: StorageKey.folderBookmark)
    }

    /// Resolves the saved bookmark, refreshing it when the system reports it stale.
    func resolve() -> URL? {
        guard let data = store.data(forKey: StorageKey.folderBookmark) else { return nil }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        // A stale bookmark still resolves, but only once — re-save it now or the
        // folder is lost on the next launch.
        if isStale { save(url) }
        return url
    }

    func clear() {
        store.remove(forKey: StorageKey.folderBookmark)
    }
}
