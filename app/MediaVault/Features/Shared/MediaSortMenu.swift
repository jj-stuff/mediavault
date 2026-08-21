import SwiftUI

/// The sort picker used by every media grid, so the three of them cannot end up
/// offering three different sets of orders.
struct MediaSortMenu: View {
    @Binding var order: MediaSortOrder

    var body: some View {
        Menu {
            Picker("Sort", selection: $order) {
                ForEach(MediaSortOrder.allCases) { option in
                    Label(option.label, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort, currently \(order.label)")
    }
}
