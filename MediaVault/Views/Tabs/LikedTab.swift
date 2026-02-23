import SwiftUI

struct LikedTab: View {
    @Environment(LikesService.self) private var likesService
    @State private var filterType: MediaItemType? = nil
    @State private var searchText = ""
    @State private var selectedItem: MediaItem?
    @State private var frozenItems: [MediaItem] = []
    let rootURL: URL?

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    private var filteredItems: [LikedItem] {
        var items = likesService.likedItems
        if let f = filterType { items = items.filter { $0.mediaType == f } }
        if !searchText.isEmpty {
            items = items.filter { $0.profileName.localizedCaseInsensitiveContains(searchText) }
        }
        return items
    }

    var body: some View {
        NavigationStack {
            Group {
                if likesService.likedItems.isEmpty {
                    ContentUnavailableView {
                        Label("No Liked Items", systemImage: "heart.slash")
                    } description: {
                        Text("Double-tap or use the heart button to like media.\nYour favorites will appear here.")
                    }
                } else {
                    likedGrid
                }
            }
            .navigationTitle("Liked")
            .searchable(text: $searchText, prompt: "Search liked items...")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                if !likesService.likedItems.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("\(likesService.likedItems.count) items").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var likedGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(filteredItems) { likedItem in
                    LikedGridCell(likedItem: likedItem, rootURL: rootURL)
                        .onTapGesture {
                            guard let rootURL else { return }
                            // Freeze the list at tap time so the cover stays stable
                            // even when likes change while it's open.
                            frozenItems = likesService.likedItems.map {
                                $0.toMediaItem(rootURL: rootURL, profileID: UUID())
                            }
                            selectedItem = likedItem.toMediaItem(rootURL: rootURL, profileID: UUID())
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation { likesService.unlike(item: likedItem) }
                            } label: { Label("Unlike", systemImage: "heart.slash") }
                        }
                }
            }
        }
        .fullScreenCover(item: $selectedItem) { item in
            FullScreenMediaView(items: frozenItems, initialItem: item, rootURL: rootURL)
        }
    }

    private var filterMenu: some View {
        Menu {
            Button { filterType = nil } label: { HStack { Text("All"); if filterType == nil { Image(systemName: "checkmark") } } }
            Button { filterType = .image } label: { HStack { Text("Images"); if filterType == .image { Image(systemName: "checkmark") } } }
            Button { filterType = .video } label: { HStack { Text("Videos"); if filterType == .video { Image(systemName: "checkmark") } } }
            Divider()
            Button(role: .destructive) { likesService.clearAll() } label: { Label("Clear All Likes", systemImage: "trash") }
        } label: { Image(systemName: "line.3.horizontal.decrease") }
    }
}

struct LikedGridCell: View {
    let likedItem: LikedItem
    let rootURL: URL?
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
            } else {
                Rectangle().fill(Color(.systemGray5)).aspectRatio(1, contentMode: .fit)
                    .overlay { Image(systemName: likedItem.mediaType == .video ? "video" : "photo").foregroundStyle(.secondary) }
            }
            Text(likedItem.profileName).font(.system(size: 9)).fontWeight(.medium).foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 2).background(.ultraThinMaterial, in: Capsule()).padding(4)
            if likedItem.mediaType == .video {
                VStack { HStack { Spacer(); Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white).padding(4).background(.ultraThinMaterial, in: Circle()).padding(4) }; Spacer() }
            }
        }
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let rootURL else { return }
        let url = likedItem.resolvedURL(rootURL: rootURL)
        let item = MediaItem(id: likedItem.id, url: url, fileName: url.lastPathComponent, mediaType: likedItem.mediaType, profileID: UUID(), profileName: likedItem.profileName, subfolder: nil)
        thumbnail = await ThumbnailService.shared.thumbnail(for: item)
    }
}
