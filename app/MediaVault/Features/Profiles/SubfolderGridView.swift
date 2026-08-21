import SwiftUI

/// One subfolder of a profile, as a grid.
///
/// Identified by profile id and folder name rather than handed a list of items: a
/// navigation destination is given a snapshot of whatever it was pushed with, so an
/// array passed in here would still contain files the user had just deleted.
struct SubfolderGridView: View {
    let profileID: UUID
    let subfolder: String

    @Environment(MediaScannerService.self) private var scanner
    @Environment(LibraryController.self) private var library
    @Environment(MediaDeletionService.self) private var deletion

    @AppStorage(StorageKey.mediaSortOrder) private var sortOrderRaw = MediaSortOrder.nameAscending.rawValue
    @State private var selectedItem: MediaItem?
    @State private var selection = MediaSelection()
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteFailure: String?

    private var sortOrder: Binding<MediaSortOrder> {
        Binding(
            get: { MediaSortOrder(rawValue: sortOrderRaw) ?? .nameAscending },
            set: { sortOrderRaw = $0.rawValue }
        )
    }

    private var sortedItems: [MediaItem] {
        let items = scanner.profiles
            .first { $0.id == profileID }?
            .mediaItems
            .filter { $0.subfolder == subfolder } ?? []
        return sortOrder.wrappedValue.sorted(items)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MediaGrid.columns, spacing: MediaGrid.spacing) {
                ForEach(sortedItems) { item in
                    SelectableGridItem(id: item.id, selection: selection) {
                        selectedItem = item
                    } cell: {
                        MediaGridCell(item: item)
                    }
                }
            }
            .padding(.bottom, ScreenInsets.gridBottomClearance)
        }
        .navigationTitle(selection.isActive ? "" : subfolder)
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
                        .disabled(sortedItems.isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selection.isActive {
                SelectionActionBar(
                    count: selection.count,
                    isEverythingSelected: selection.coversAll(sortedItems),
                    onSelectAll: { selection.selectAll(sortedItems) },
                    onDeselectAll: { selection.deselectAll() },
                    onDelete: { isConfirmingDelete = true }
                )
            }
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
            FullScreenMediaView(items: sortedItems, initialItem: item)
        }
    }

    private func deleteSelection() async {
        let items = selection.resolve(in: sortedItems)
        guard !items.isEmpty else { return }

        isDeleting = true
        let outcome = await deletion.delete(items, rootURL: library.activeRootURL)
        isDeleting = false

        deleteFailure = outcome.failureMessage
        selection.end()
    }
}
