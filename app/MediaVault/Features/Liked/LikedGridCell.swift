import SwiftUI

struct LikedGridCell: View {
    let likedItem: LikedItem
    let mediaItem: MediaItem?

    var body: some View {
        MediaThumbnail(item: mediaItem) {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay {
                    Image(systemName: likedItem.mediaType == .video ? "video" : "photo")
                        .foregroundStyle(.secondary)
                }
        }
        .overlay(alignment: .bottomLeading) {
            Text(likedItem.profileName)
                .font(.system(size: 9))
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial, in: .capsule)
                .padding(4)
        }
        .overlay(alignment: .topTrailing) {
            if likedItem.mediaType == .video {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.ultraThinMaterial, in: .circle)
                    .padding(4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(likedItem.mediaType == .video ? "Video" : "Photo") from \(likedItem.profileName)"
        )
    }
}
