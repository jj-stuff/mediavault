import SwiftUI

struct ZoomableImageView: View {
    let url: URL
    @Binding var showOverlay: Bool

    @Environment(ImageLoader.self) private var imageLoader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView(image: image, showOverlay: $showOverlay)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task(id: url) {
            image = await imageLoader.fullImage(for: url)
        }
    }
}
