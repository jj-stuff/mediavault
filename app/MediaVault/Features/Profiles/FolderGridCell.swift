import SwiftUI

struct FolderGridCell: View {
    let group: SubfolderGroup

    private var coverItem: MediaItem? {
        group.items.first { $0.mediaType == .image } ?? group.items.first
    }

    var body: some View {
        MediaThumbnail(item: coverItem) {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.caption2)
                Text(group.name)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text(group.items.count, format: .number)
                    .font(.caption2)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(group.name), \(group.items.count) items")
    }
}
