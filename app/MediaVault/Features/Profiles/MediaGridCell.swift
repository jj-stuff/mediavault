import SwiftUI

struct MediaGridCell: View {
    let item: MediaItem

    var body: some View {
        MediaThumbnail(item: item) {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay { ProgressView() }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.mediaType == .video {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.ultraThinMaterial, in: .circle)
                    .padding(4)
            }
        }
        .accessibilityLabel(item.mediaType == .video ? "Video, \(item.fileName)" : "Photo, \(item.fileName)")
    }
}
