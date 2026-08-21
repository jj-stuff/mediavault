import SwiftUI

/// Photos-style multi-select for a media grid: which cells are ticked, and whether
/// the grid is in that mode at all.
///
/// A class rather than a pair of `@State` values because three grids need exactly
/// the same behaviour, and because the action bar and the cells have to agree about
/// it without each grid re-deriving "is everything selected" for itself.
@Observable
final class MediaSelection {

    private(set) var isActive = false
    private(set) var ids: Set<UUID> = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Enters selection mode. Starting empty is deliberate: leaving the previous
    /// selection ticked would arm a delete button the user did not aim.
    func begin() {
        isActive = true
        ids = []
    }

    func end() {
        isActive = false
        ids = []
    }

    func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func selectAll(_ items: [MediaItem]) {
        ids = Set(items.map(\.id))
    }

    func deselectAll() {
        ids = []
    }

    /// True when every item on screen is ticked, so the button can offer the
    /// opposite of whatever the user has already done.
    func coversAll(_ items: [MediaItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { ids.contains($0.id) }
    }

    /// The selected items, in the order the grid shows them.
    ///
    /// Taken from the grid rather than remembered here: an item can disappear from
    /// under a selection — a rescan, an unlike — and a delete must act on what is
    /// still really there.
    func resolve(in items: [MediaItem]) -> [MediaItem] {
        items.filter { ids.contains($0.id) }
    }
}

// MARK: - Cell decoration

extension View {
    /// Ticks a grid cell, Photos-style.
    func selectionBadge(isSelecting: Bool, isSelected: Bool) -> some View {
        modifier(SelectionBadge(isSelecting: isSelecting, isSelected: isSelected))
    }
}

private struct SelectionBadge: ViewModifier {
    let isSelecting: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isSelecting && isSelected {
                    Color.accentColor.opacity(0.28)
                }
            }
            // Top-leading, where Photos puts it bottom-trailing: that corner already
            // carries the video badge in one grid and the profile name in another,
            // and two overlapping circles read worse than a moved tick.
            .overlay(alignment: .topLeading) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.35))
                        .shadow(radius: 1)
                        .padding(6)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .animation(.easeOut(duration: 0.15), value: isSelecting)
    }
}

// MARK: - Action bar

/// The bar that replaces the tab bar while a grid is selecting.
///
/// Its own view rather than a `.bottomBar` toolbar: these grids live inside the
/// app's tab bar, and a toolbar placement there fights it for the same strip of
/// screen.
struct SelectionActionBar<Extra: View>: View {
    let count: Int
    let isEverythingSelected: Bool
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 16) {
            Button(isEverythingSelected ? "Deselect All" : "Select All") {
                isEverythingSelected ? onDeselectAll() : onSelectAll()
            }

            Spacer()

            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .monospacedDigit()

            Spacer()

            extra()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.title3)
            }
            .disabled(count == 0)
            .accessibilityLabel("Move \(count) items to Trash")
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var label: String {
        switch count {
        case 0: "Select Items"
        case 1: "1 Selected"
        default: "\(count) Selected"
        }
    }
}

extension SelectionActionBar where Extra == EmptyView {
    init(
        count: Int,
        isEverythingSelected: Bool,
        onSelectAll: @escaping () -> Void,
        onDeselectAll: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.init(
            count: count,
            isEverythingSelected: isEverythingSelected,
            onSelectAll: onSelectAll,
            onDeselectAll: onDeselectAll,
            onDelete: onDelete,
            extra: { EmptyView() }
        )
    }
}

// MARK: - Grid cell

/// A grid cell that ticks when the grid is selecting and opens the viewer when it
/// is not, with a long press to start selecting — the gesture Photos uses.
///
/// Written once because all three grids need identical behaviour, and because
/// getting it wrong in one of them means a tap that deletes the wrong thing.
struct SelectableGridItem<Cell: View>: View {
    let id: UUID
    let selection: MediaSelection
    let onOpen: () -> Void
    @ViewBuilder var cell: () -> Cell

    var body: some View {
        Button {
            if selection.isActive {
                selection.toggle(id)
            } else {
                onOpen()
            }
        } label: {
            cell()
                .selectionBadge(
                    isSelecting: selection.isActive,
                    isSelected: selection.contains(id)
                )
        }
        .buttonStyle(.plain)
        // `simultaneousGesture`, not `onLongPressGesture`: the latter takes the
        // press away from the button, and the cell stops opening on a plain tap.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard !selection.isActive else { return }
                selection.begin()
                selection.toggle(id)
            }
        )
    }
}

// MARK: - Delete flow

extension View {
    /// The confirmation, the progress cover, and the failure alert that every
    /// selecting grid needs, worded the same way in each of them.
    func selectionDelete(
        count: Int,
        isConfirming: Binding<Bool>,
        isDeleting: Bool,
        failure: Binding<String?>,
        perform: @escaping () -> Void
    ) -> some View {
        modifier(
            SelectionDeleteFlow(
                count: count,
                isConfirming: isConfirming,
                isDeleting: isDeleting,
                failure: failure,
                perform: perform
            )
        )
    }
}

private struct SelectionDeleteFlow: ViewModifier {
    let count: Int
    @Binding var isConfirming: Bool
    let isDeleting: Bool
    @Binding var failure: String?
    let perform: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive, action: perform)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Files move to the Trash folder, or are deleted outright if the library has no writable Trash.")
            }
            .alert("Delete Failed", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .overlay {
                if isDeleting {
                    // Blocking on purpose: a few hundred files over the network take
                    // long enough that a second tap on the trash button is likely,
                    // and the second one would act on a list already being deleted.
                    ProgressView("Deleting…")
                        .padding(24)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.15))
                }
            }
    }

    private var title: String {
        count == 1 ? "Move 1 Item to Trash?" : "Move \(count) Items to Trash?"
    }
}
