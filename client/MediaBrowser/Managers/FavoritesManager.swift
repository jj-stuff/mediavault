import Foundation

final class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()

    @Published private(set) var favoriteIDs: Set<String> = []

    private let favoritesKey = "UserFavorites"
    private let queue = DispatchQueue(label: "favorites.queue", attributes: .concurrent)

    private init() {
        loadFavorites()
    }

    func toggleFavorite(_ item: MediaItem) {
        Task { @MainActor in
            if favoriteIDs.contains(item.uniqueID) {
                favoriteIDs.remove(item.uniqueID)
            } else {
                favoriteIDs.insert(item.uniqueID)
            }
            saveFavorites()
        }
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        favoriteIDs.contains(item.uniqueID)
    }

    private func loadFavorites() {
        queue.async(flags: .barrier) { [weak self] in
            guard
                let data = UserDefaults.standard.data(forKey: self?.favoritesKey ?? ""),
                let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
            else { return }

            Task { @MainActor in
                self?.favoriteIDs = decoded
            }
        }
    }

    @MainActor
    private func saveFavorites() {
        let favorites = favoriteIDs
        queue.async(flags: .barrier) { [weak self] in
            guard let key = self?.favoritesKey,
                  let encoded = try? JSONEncoder().encode(favorites)
            else { return }

            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}
