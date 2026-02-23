import Foundation

@Observable
final class LikesService {
    var likedItems: [LikedItem] = []
    private let storageKey = "likedMediaItems"

    init() { loadLikes() }

    func isLiked(mediaItem: MediaItem, rootURL: URL) -> Bool {
        let relativePath = Self.relativePath(for: mediaItem, rootURL: rootURL)
        return likedItems.contains { Self.normalize($0.relativePath) == relativePath }
    }

    func toggleLike(mediaItem: MediaItem, rootURL: URL) {
        let relativePath = Self.relativePath(for: mediaItem, rootURL: rootURL)
        if let index = likedItems.firstIndex(where: { Self.normalize($0.relativePath) == relativePath }) {
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

    func clearAll() {
        likedItems.removeAll()
        saveLikes()
    }

    private func saveLikes() {
        if let data = try? JSONEncoder().encode(likedItems) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadLikes() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([LikedItem].self, from: data)
        else { return }
        likedItems = items
    }

    private static func relativePath(for item: MediaItem, rootURL: URL) -> String {
        let fullPath = item.url.path
        let rootPath = rootURL.path
        let raw = fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : item.url.lastPathComponent
        return normalize(raw)
    }

    // Strip leading slash so paths computed from different code paths compare equal.
    private static func normalize(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}
