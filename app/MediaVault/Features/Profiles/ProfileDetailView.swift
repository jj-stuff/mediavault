import SwiftUI

struct ProfileDetailView: View {
    let profile: MediaProfile

    @Environment(LibraryController.self) private var library
    @AppStorage(StorageKey.flattenFolders) private var flattenFolders = true
    @State private var filterType: FilterType = .all
    @State private var selectedSubfolder: String?
    @State private var selectedItem: MediaItem?

    enum FilterType: String, CaseIterable, Identifiable {
        case all = "All", images = "Images", videos = "Videos"
        var id: Self { self }
    }

    /// Items in the main grid. In hierarchical mode only root-level items appear
    /// here; everything else is reached through a folder card.
    private var displayedItems: [MediaItem] {
        var items = flattenFolders
            ? profile.mediaItems
            : profile.mediaItems.filter { $0.subfolder == nil }

        if flattenFolders, let selectedSubfolder {
            items = items.filter { $0.subfolder == selectedSubfolder }
        }

        switch filterType {
        case .all: break
        case .images: items = items.filter { $0.mediaType == .image }
        case .videos: items = items.filter { $0.mediaType == .video }
        }

        return items
    }

    private var subfolderGroups: [SubfolderGroup] {
        guard !flattenFolders else { return [] }
        return profile.subfolders.map { name in
            SubfolderGroup(
                name: name,
                items: profile.mediaItems.filter { $0.subfolder == name }
            )
        }
    }

    var body: some View {
        ScrollView {
            profileHeader
            filterBar

            LazyVGrid(columns: MediaGrid.columns, spacing: MediaGrid.spacing) {
                ForEach(subfolderGroups) { group in
                    NavigationLink {
                        SubfolderGridView(items: group.items, title: group.name)
                    } label: {
                        FolderGridCell(group: group)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(displayedItems) { item in
                    Button {
                        selectedItem = item
                    } label: {
                        MediaGridCell(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedItem) { item in
            FullScreenMediaView(items: displayedItems, initialItem: item)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 24) {
            StatBadge(count: profile.totalCount, label: "Total")
            StatBadge(count: profile.imageCount, label: "Photos")
            StatBadge(count: profile.videoCount, label: "Videos")
            if !profile.subfolders.isEmpty {
                StatBadge(count: profile.subfolders.count, label: "Folders")
            }
        }
        .padding()
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(FilterType.allCases) { type in
                    FilterChip(title: type.rawValue, isSelected: filterType == type) {
                        filterType = type
                    }
                }

                if flattenFolders && !profile.subfolders.isEmpty {
                    Divider().frame(height: 24)

                    FilterChip(title: "All Folders", isSelected: selectedSubfolder == nil) {
                        selectedSubfolder = nil
                    }
                    ForEach(profile.subfolders, id: \.self) { folder in
                        FilterChip(title: folder, isSelected: selectedSubfolder == folder) {
                            selectedSubfolder = folder
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 4)
    }
}

/// Shared grid metrics, so the profile grid, subfolder grid, and Liked grid cannot
/// drift apart.
enum MediaGrid {
    static let spacing: CGFloat = 2
    static let columns = Array(
        repeating: GridItem(.flexible(), spacing: spacing),
        count: 3
    )
}

struct SubfolderGroup: Identifiable {
    let name: String
    let items: [MediaItem]
    var id: String { name }
}
