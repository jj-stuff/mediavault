import SwiftUI

/// Picks the right renderer for a media item inside the full-screen viewer.
struct MediaContentView: View {
    let item: MediaItem
    @Binding var showOverlay: Bool

    /// True only for the page actually on screen.
    ///
    /// A paged `TabView` builds its neighbours ahead of time, so without this every
    /// adjacent video started playing the moment it was constructed — three
    /// soundtracks at once, and the one you could hear was not the one you could see.
    let isActive: Bool

    var body: some View {
        switch item.mediaType {
        case .image:
            ZoomableImageView(url: item.url, showOverlay: $showOverlay)
        case .video:
            VideoContentView(url: item.url, isActive: isActive)
        }
    }
}
