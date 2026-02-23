import SwiftUI

struct ProfileDetailView: View {
    let profile: MediaProfile
    let rootURL: URL?
    @Environment(LikesService.self) private var likesService
    @AppStorage("flattenFolders") private var flattenFolders = true
    @State private var filterType: FilterType = .all
    @State private var selectedSubfolder: String? = nil
    @State private var selectedItem: MediaItem?

    enum FilterType: String, CaseIterable { case all = "All", images = "Images", videos = "Videos" }

    // Items shown in the main grid. In hierarchical mode only root-level items appear here.
    private var displayedItems: [MediaItem] {
        var items = flattenFolders
            ? profile.mediaItems
            : profile.mediaItems.filter { $0.subfolder == nil }
        if flattenFolders, let sub = selectedSubfolder {
            items = items.filter { $0.subfolder == sub }
        }
        switch filterType {
        case .all: break
        case .images: items = items.filter { $0.mediaType == .image }
        case .videos: items = items.filter { $0.mediaType == .video }
        }
        return items
    }

    // Subfolder groups used for navigation cards in hierarchical mode.
    private var subfolderGroups: [(name: String, items: [MediaItem])] {
        guard !flattenFolders else { return [] }
        return profile.subfolders.map { name in
            (name, profile.mediaItems.filter { $0.subfolder == name })
        }
    }

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        ScrollView {
            profileHeader
            filterBar
            LazyVGrid(columns: columns, spacing: 2) {
                // Folder cards (hierarchical mode only)
                ForEach(subfolderGroups, id: \.name) { group in
                    NavigationLink(destination: SubfolderGridView(
                        items: group.items, title: group.name, rootURL: rootURL
                    )) {
                        FolderGridCell(name: group.name, items: group.items)
                    }
                    .buttonStyle(.plain)
                }
                // Media items
                ForEach(displayedItems) { item in
                    MediaGridCell(item: item)
                        .onTapGesture { selectedItem = item }
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedItem) { item in
            FullScreenMediaView(items: displayedItems, initialItem: item, rootURL: rootURL)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 24) {
            StatBadge(count: profile.totalCount, label: "Total")
            StatBadge(count: profile.imageCount, label: "Photos")
            StatBadge(count: profile.videoCount, label: "Videos")
            if !profile.subfolders.isEmpty { StatBadge(count: profile.subfolders.count, label: "Folders") }
        }
        .padding()
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterType.allCases, id: \.self) { type in
                    FilterChip(title: type.rawValue, isSelected: filterType == type) { filterType = type }
                }
                // Subfolder filter chips only in flat mode
                if flattenFolders && !profile.subfolders.isEmpty {
                    Divider().frame(height: 24)
                    FilterChip(title: "All Folders", isSelected: selectedSubfolder == nil) { selectedSubfolder = nil }
                    ForEach(profile.subfolders, id: \.self) { folder in
                        FilterChip(title: folder, isSelected: selectedSubfolder == folder) { selectedSubfolder = folder }
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Subfolder navigation view

struct SubfolderGridView: View {
    let items: [MediaItem]
    let title: String
    let rootURL: URL?
    @State private var selectedItem: MediaItem?

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    MediaGridCell(item: item)
                        .onTapGesture { selectedItem = item }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedItem) { item in
            FullScreenMediaView(items: items, initialItem: item, rootURL: rootURL)
        }
    }
}

// MARK: - Folder grid cell

struct FolderGridCell: View {
    let name: String
    let items: [MediaItem]
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
            } else {
                Rectangle().fill(Color(.systemGray5)).aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
            }
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.caption2).foregroundStyle(.white)
                Text(name).font(.caption2).fontWeight(.medium).lineLimit(1).foregroundStyle(.white)
                Spacer()
                Text("\(items.count)").font(.caption2).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.ultraThinMaterial)
        }
        .task {
            if let firstImage = items.first(where: { $0.mediaType == .image }) {
                thumbnail = await ThumbnailService.shared.thumbnail(for: firstImage)
            }
        }
    }
}

// MARK: - Shared components

struct StatBadge: View {
    let count: Int; let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title3).fontWeight(.bold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FilterChip: View {
    let title: String; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.caption).fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isSelected ? Color.primary.opacity(0.9) : Color(.systemGray5))
                .foregroundStyle(isSelected ? Color(.systemBackground) : .primary)
                .clipShape(Capsule())
        }
    }
}

struct MediaGridCell: View {
    let item: MediaItem
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipped()
            } else {
                Rectangle().fill(Color(.systemGray5)).aspectRatio(1, contentMode: .fit)
                    .overlay { ProgressView() }
            }
            if item.mediaType == .video {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                    .padding(6).background(.ultraThinMaterial, in: Circle()).padding(4)
            }
        }
        .task { thumbnail = await ThumbnailService.shared.thumbnail(for: item) }
    }
}
