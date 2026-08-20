import SwiftUI

struct LikedTab: View {
    @Environment(LikesService.self) private var likes
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LibraryController.self) private var library

    @State private var filterType: MediaItemType?
    @State private var searchText = ""
    @State private var presentedViewer: ViewerSelection?

    private var filteredItems: [LikedItem] {
        var items = likes.likedItems
        if let filterType {
            items = items.filter { $0.mediaType == filterType }
        }
        if !searchText.isEmpty {
            items = items.filter { $0.profileName.localizedCaseInsensitiveContains(searchText) }
        }
        return items
    }

    var body: some View {
        NavigationStack {
            Group {
                if likes.likedItems.isEmpty {
                    ContentUnavailableView {
                        Label("No Liked Items", systemImage: "heart.slash")
                    } description: {
                        Text("Tap the heart on any photo or video.\nYour favourites appear here.")
                    }
                } else if filteredItems.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    likedGrid
                }
            }
            .navigationTitle("Liked")
            .searchable(text: $searchText, prompt: "Search liked items")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                if !likes.likedItems.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("\(likes.likedItems.count) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .fullScreenCover(item: $presentedViewer) { selection in
                FullScreenMediaView(items: selection.items, initialItem: selection.initialItem)
            }
        }
    }

    private var likedGrid: some View {
        ScrollView {
            LazyVGrid(columns: MediaGrid.columns, spacing: MediaGrid.spacing) {
                ForEach(filteredItems) { likedItem in
                    Button {
                        present(likedItem)
                    } label: {
                        LikedGridCell(likedItem: likedItem, mediaItem: mediaItem(for: likedItem))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Unlike", systemImage: "heart.slash", role: .destructive) {
                            withAnimation { likes.unlike(item: likedItem) }
                        }
                    }
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filterType) {
                Text("All").tag(MediaItemType?.none)
                Text("Images").tag(MediaItemType?.some(.image))
                Text("Videos").tag(MediaItemType?.some(.video))
            }
            Divider()
            Button("Clear All Likes", systemImage: "trash", role: .destructive) {
                likes.clearAll()
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
    }

    // MARK: - Presentation

    /// Snapshots the list at tap time.
    ///
    /// Two reasons: unliking from inside the viewer would otherwise pull items out
    /// from under the user mid-swipe, and the viewer should page through what is
    /// actually on screen — the previous version handed it the full unfiltered list,
    /// so swiping escaped the active filter.
    private func present(_ likedItem: LikedItem) {
        guard library.activeRootURL != nil else { return }
        let items = filteredItems.compactMap(mediaItem(for:))
        guard let initial = mediaItem(for: likedItem) else { return }
        presentedViewer = ViewerSelection(items: items, initialItem: initial)
    }

    /// Resolves a like back into a media item against the current library root.
    ///
    /// The profile id is looked up by name so the viewer can still reach the
    /// profile; a like only records the name, not the id.
    private func mediaItem(for likedItem: LikedItem) -> MediaItem? {
        guard let rootURL = library.activeRootURL else { return nil }
        let profileID = scanner.profiles
            .first { $0.name == likedItem.profileName }?.id ?? likedItem.id
        return likedItem.toMediaItem(rootURL: rootURL, profileID: profileID)
    }

    struct ViewerSelection: Identifiable {
        let items: [MediaItem]
        let initialItem: MediaItem
        var id: UUID { initialItem.id }
    }
}
