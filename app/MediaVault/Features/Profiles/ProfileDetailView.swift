import SwiftUI

struct ProfileDetailView: View {
    /// The profile as it was when this screen was pushed. Read through `profile`,
    /// which prefers the scanner's current copy — see below.
    let pushedProfile: MediaProfile

    @Environment(LibraryController.self) private var library
    @Environment(MediaDeletionService.self) private var deletion
    @Environment(MediaScannerService.self) private var scanner
    @AppStorage(StorageKey.flattenFolders) private var flattenFolders = true
    @AppStorage(StorageKey.mediaSortOrder) private var sortOrderRaw = MediaSortOrder.nameAscending.rawValue
    @State private var filterType: FilterType = .all
    @State private var selectedSubfolder: String?
    @State private var selectedItem: MediaItem?
    @State private var selection = MediaSelection()
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteFailure: String?

    /// The live profile, falling back to the value this screen was pushed with.
    ///
    /// A navigation destination is handed a *snapshot* of its value, so deleting
    /// items left them on screen until the next rescan: the grid was reading a copy
    /// of the library made before the delete. Looking the profile up by id each time
    /// means a delete — one item or fifty — takes effect where the user did it.
    private var profile: MediaProfile {
        scanner.profiles.first { $0.id == pushedProfile.id } ?? pushedProfile
    }

    enum FilterType: String, CaseIterable, Identifiable {
        case all = "All", images = "Images", videos = "Videos"
        var id: Self { self }
    }

    /// Persisted as a raw string so a future case cannot make the stored value
    /// undecodable; an unknown one falls back to name order.
    private var sortOrder: Binding<MediaSortOrder> {
        Binding(
            get: { MediaSortOrder(rawValue: sortOrderRaw) ?? .nameAscending },
            set: { sortOrderRaw = $0.rawValue }
        )
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

        return sortOrder.wrappedValue.sorted(items)
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
                        SubfolderGridView(profileID: profile.id, subfolder: group.name)
                    } label: {
                        FolderGridCell(group: group)
                    }
                    .buttonStyle(.plain)
                    // A folder is not one of the things being selected, and pushing
                    // a screen mid-selection would strand the ticks behind it.
                    .disabled(selection.isActive)
                }

                ForEach(displayedItems) { item in
                    SelectableGridItem(id: item.id, selection: selection) {
                        selectedItem = item
                    } cell: {
                        MediaGridCell(item: item)
                    }
                }
            }
            // Without this the last row sits under the tab bar, and since the scroll
            // view has already reached its end there is no way to bring it up.
            .padding(.bottom, ScreenInsets.gridBottomClearance)
        }
        .refreshable { await library.refresh() }
        .navigationTitle(selection.isActive ? "" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selection.isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selection.end() }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) { MediaSortMenu(order: sortOrder) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { selection.begin() }
                        .disabled(displayedItems.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive { selectionBar }
        }
        // The bar stands in for the tab bar rather than sitting on top of it.
        .toolbar(selection.isActive ? .hidden : .automatic, for: .tabBar)
        .selectionDelete(
            count: selection.count,
            isConfirming: $isConfirmingDelete,
            isDeleting: isDeleting,
            failure: $deleteFailure
        ) {
            Task { await deleteSelection() }
        }
        .fullScreenCover(item: $selectedItem) { item in
            FullScreenMediaView(items: displayedItems, initialItem: item)
        }
    }

    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            isEverythingSelected: selection.coversAll(displayedItems),
            onSelectAll: { selection.selectAll(displayedItems) },
            onDeselectAll: { selection.deselectAll() },
            onDelete: { isConfirmingDelete = true }
        )
    }

    /// Deletes the ticked items, then leaves selection mode.
    ///
    /// The list is resolved against what is on screen right now, so a rescan that
    /// landed while the confirmation was up cannot delete something the user can no
    /// longer see.
    private func deleteSelection() async {
        let items = selection.resolve(in: displayedItems)
        guard !items.isEmpty else { return }

        isDeleting = true
        let outcome = await deletion.delete(items, rootURL: library.activeRootURL)
        isDeleting = false

        deleteFailure = outcome.failureMessage
        selection.end()
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
