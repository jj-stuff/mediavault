import SwiftUI

struct StatBadge: View {
    let count: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(count, format: .number)
                .font(.title3)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Otherwise VoiceOver reads the number and the label as two separate items.
        .accessibilityElement(children: .combine)
    }
}
