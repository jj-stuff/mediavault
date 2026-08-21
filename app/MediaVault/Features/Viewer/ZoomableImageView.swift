import SwiftUI

/// One image page of the full-screen viewer.
///
/// Draws the best picture it already has in memory on its very first frame and
/// swaps in the full-size decode when that lands. Waiting for the decode instead —
/// which is what a bare `ProgressView` amounts to — is what made paging between
/// photos feel like it stalled: the file the grid had already downloaded was sitting
/// in the cache the whole time.
struct ZoomableImageView: View {
    let url: URL
    @Binding var showOverlay: Bool

    @Environment(ImageLoader.self) private var imageLoader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView(image: image, showOverlay: $showOverlay)
            } else if let thumbnail = imageLoader.cachedThumbnail(for: url) {
                // Deliberately not zoomable: this is a placeholder measured in
                // hundreds of pixels, and it is on screen for a few frames.
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { showOverlay.toggle() }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task(id: url) {
            // The cache hit is taken without awaiting, so returning to a photo that
            // has already been decoded never blanks the screen first.
            if let cached = imageLoader.cachedFullImage(for: url) {
                image = cached
                return
            }
            // Only clear once we know a decode is actually needed; clearing first
            // would drop a good image to show a placeholder for the same URL.
            image = nil
            image = await imageLoader.fullImage(for: url)
        }
    }
}
