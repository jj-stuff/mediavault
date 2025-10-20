import SwiftUI

struct LikedView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @State private var allLikedItems: [MediaItem] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            if allLikedItems.isEmpty && !isLoading {
                emptyState
            } else {
                ScrollView {
                    MediaGridView(mediaItems: allLikedItems)
                }
            }
        }
        .navigationTitle("Liked")
        .task {
            await loadLikedItems()
        }
        .refreshable {
            await loadLikedItems()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.slash")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("No liked items yet")
                .foregroundColor(.secondary)
        }
    }

    private func loadLikedItems() async {
        isLoading = true
        var aggregatedItems: [MediaItem] = []

        if networkManager.users.isEmpty {
            await networkManager.fetchUsers()
        }

        await withTaskGroup(of: [MediaItem].self) { group in
            for user in networkManager.users {
                group.addTask {
                    let userMedia = await networkManager.fetchUserMedia(username: user.username)
                    return userMedia.values
                        .flatMap { $0 }
                        .filter { favoritesManager.isFavorite($0) }
                }
            }

            for await items in group {
                aggregatedItems.append(contentsOf: items)
            }
        }

        await MainActor.run {
            allLikedItems = aggregatedItems
            isLoading = false
        }
    }
}
