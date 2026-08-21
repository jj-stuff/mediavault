import SwiftUI

struct LikedTab: View {
    @Environment(LikesService.self) private var likes
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LibraryController.self) private var library
    @Environment(MediaDeletionService.self) private var deletion

    @State private var filterType: MediaItemType?
    @State private var searchText = ""
    @State private var presentedViewer: ViewerSelection?
    @State private var selection = MediaSelection()
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteFailure: String?

    /// The filtered likes resolved against the current library.
    ///
    /// A like whose file cannot be resolved — no library root yet — is not
    /// selectable, so this is also what selection and deletion work from.
    private var resolvedItems: [MediaItem] {
        filteredItems.compactMap(mediaItem(for:))
    }

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
                if selection.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selection.end() }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) { filterMenu }
                    if !filteredItems.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Select") { selection.begin() }
                                .disabled(resolvedItems.isEmpty)
                        }
                    }
                    if !likes.likedItems.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Text("\(likes.likedItems.count) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selection.isActive { selectionBar }
            }
            .toolbar(selection.isActive ? .hidden : .automatic, for: .tabBar)
            .selectionDelete(
                count: selection.count,
                isConfirming: $isConfirmingDelete,
                isDeleting: isDeleting,
                failure: $deleteFailure
            ) {
                Task { await deleteSelection() }
            }
            .fullScreenCover(item: $presentedViewer) { viewer in
                FullScreenMediaView(items: viewer.items, initialItem: viewer.initialItem)
            }
        }
    }

    /// Two destructive actions, deliberately distinct: unliking is about this list,
    /// moving to Trash is about the files. Photos conflates them; here the Liked tab
    /// is a view onto a library the user also browses by profile.
    private var selectionBar: some View {
        SelectionActionBar(
            count: selection.count,
            isEverythingSelected: selection.coversAll(resolvedItems),
            onSelectAll: { selection.selectAll(resolvedItems) },
            onDeselectAll: { selection.deselectAll() },
            onDelete: { isConfirmingDelete = true }
        ) {
            Button {
                unlikeSelection()
            } label: {
                Image(systemName: "heart.slash")
                    .font(.title3)
            }
            .disabled(selection.isEmpty)
            .accessibilityLabel("Unlike \(selection.count) items")
        }
    }

    private var likedGrid: some View {
        ScrollView {
            LazyVGrid(columns: MediaGrid.columns, spacing: MediaGrid.spacing) {
                ForEach(filteredItems) { likedItem in
                    // The long press that used to open an Unlike context menu now
                    // starts selection, as it does in every other grid. Unliking one
                    // item costs the same two gestures either way, and a context
                    // menu that fires alongside the selection gesture is worse than
                    // no context menu at all.
                    SelectableGridItem(id: likedItem.id, selection: selection) {
                        present(likedItem)
                    } cell: {
                        LikedGridCell(likedItem: likedItem, mediaItem: mediaItem(for: likedItem))
                    }
                }
            }
            // Clears the tab bar, which otherwise covers the last row of a grid
            // that has already scrolled as far as it can.
            .padding(.bottom, ScreenInsets.gridBottomClearance)
        }
        .refreshable { await library.refresh() }
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
        guard let initial = mediaItem(for: likedItem) else { return }
        presentedViewer = ViewerSelection(items: resolvedItems, initialItem: initial)
    }

    // MARK: - Selection actions

    /// Removes the ticked items from this list. The files are untouched.
    private func unlikeSelection() {
        let ids = selection.ids
        withAnimation {
            for likedItem in filteredItems where ids.contains(likedItem.id) {
                likes.unlike(item: likedItem)
            }
        }
        selection.end()
    }

    private func deleteSelection() async {
        let items = selection.resolve(in: resolvedItems)
        guard !items.isEmpty else { return }

        isDeleting = true
        // Deleting also unlikes, in `MediaDeletionService`, so the row leaves this
        // grid at the same moment the file leaves the library.
        let outcome = await deletion.delete(items, rootURL: library.activeRootURL)
        isDeleting = false

        deleteFailure = outcome.failureMessage
        selection.end()
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
