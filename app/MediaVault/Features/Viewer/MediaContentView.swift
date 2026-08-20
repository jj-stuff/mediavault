import SwiftUI

/// Picks the right renderer for a media item inside the full-screen viewer.
struct MediaContentView: View {
    let item: MediaItem
    @Binding var showOverlay: Bool

    var body: some View {
        switch item.mediaType {
        case .image:
            ZoomableImageView(url: item.url, showOverlay: $showOverlay)
        case .video:
            VideoContentView(url: item.url)
        }
    }
}
