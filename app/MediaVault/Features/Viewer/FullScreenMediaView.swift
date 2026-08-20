import SwiftUI

struct FullScreenMediaView: View {
    let initialItem: MediaItem

    @Environment(LikesService.self) private var likes
    @Environment(MediaDeletionService.self) private var deletion
    @Environment(LibraryController.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MediaItem]
    /// Paging is keyed on item identity rather than index.
    ///
    /// With an index, deleting an item shifts every item after it by one, so the
    /// selection silently jumps to a different photo than the one on screen.
    @State private var currentID: UUID
    @State private var showOverlay = true
    @State private var showDeleteConfirmation = false
    @State private var deleteError: String?

    init(items: [MediaItem], initialItem: MediaItem) {
        self.initialItem = initialItem
        _items = State(initialValue: items)
        _currentID = State(initialValue: initialItem.id)
    }

    private var currentItem: MediaItem? {
        items.first { $0.id == currentID }
    }

    private var currentPosition: Int? {
        items.firstIndex { $0.id == currentID }.map { $0 + 1 }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentID) {
                ForEach(items) { item in
                    MediaContentView(item: item, showOverlay: $showOverlay)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showOverlay {
                overlayControls
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showOverlay)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: showOverlay)
        .confirmationDialog(
            "Move \"\(currentItem?.fileName ?? "")\" to Trash?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await deleteCurrentItem() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is moved to the Trash folder, not erased.")
        }
        .alert("Delete Failed", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Overlay

    private var overlayControls: some View {
        VStack {
            topBar
            Spacer()
            if let currentItem, library.activeRootURL != nil {
                bottomBar(item: currentItem)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer()

            if let currentItem, let currentPosition {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentItem.profileName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("\(currentPosition) of \(items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
    }

    private func bottomBar(item: MediaItem) -> some View {
        HStack(spacing: 16) {
            if let rootURL = library.activeRootURL {
                let isLiked = likes.isLiked(mediaItem: item, rootURL: rootURL)
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        likes.toggleLike(mediaItem: item, rootURL: rootURL)
                    }
                } label: {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(isLiked ? .red : .white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLiked ? "Unlike" : "Like")
            }

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Move to Trash")

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.fileName)
                    .font(.caption2)
                    .lineLimit(1)
                if let subfolder = item.subfolder {
                    Text(subfolder)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)
        }
        .padding()
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Actions

    private func deleteCurrentItem() async {
        guard let item = currentItem,
              let index = items.firstIndex(where: { $0.id == item.id })
        else { return }

        do {
            try await deletion.delete(item, rootURL: library.activeRootURL)
        } catch {
            deleteError = error.localizedDescription
            return
        }

        // Move the selection to a neighbour *before* removing, so paging never
        // points at an id that is no longer in the list.
        let neighbour = items.indices.contains(index + 1)
            ? items[index + 1].id
            : items[safe: index - 1]?.id

        if let neighbour {
            currentID = neighbour
            items.remove(at: index)
        } else {
            dismiss()
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
