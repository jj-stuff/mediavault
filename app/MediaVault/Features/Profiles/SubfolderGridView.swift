import SwiftUI

struct SubfolderGridView: View {
    let items: [MediaItem]
    let title: String

    @State private var selectedItem: MediaItem?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: MediaGrid.columns, spacing: MediaGrid.spacing) {
                ForEach(items) { item in
                    Button {
                        selectedItem = item
                    } label: {
                        MediaGridCell(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedItem) { item in
            FullScreenMediaView(items: items, initialItem: item)
        }
    }
}
