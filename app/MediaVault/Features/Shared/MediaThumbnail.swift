import SwiftUI

/// A square thumbnail that loads itself from the shared `ImageLoader`.
///
/// Four different grid cells each carried their own `@State` image plus a `.task`
/// that called the loader; this is that pattern, written once. Keying the task on
/// the item's id matters in a lazy grid: SwiftUI reuses the view's identity as rows
/// scroll, so without it a recycled cell keeps showing the previous item's picture.
///
/// The square comes from an empty `Color`, not from the image. Sizing a
/// `.aspectRatio(contentMode: .fill)` image and *then* asking for a 1:1 fit only
/// proposes a square — the image still reports its own oversized dimensions, so the
/// view's layout frame was as wide as a landscape photo wanted to be and the
/// `clipShape` had nothing to clip against. In a `LazyVGrid` that frame overlapped
/// the neighbouring cell, and because the grid under-measured its own content
/// height, the last row could not be scrolled into view. Here the `Color` fixes the
/// frame at 1:1 and the image rides along in an overlay, where overflow is clipped.
struct MediaThumbnail<Placeholder: View>: View {
    let item: MediaItem?
    var size: CGSize = ImageLoader.thumbnailSize
    var cornerRadius: CGFloat = 0
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(ImageLoader.self) private var imageLoader
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            // `.fill`, not `.fit`: a grid cell is proposed a definite width and an
            // unspecified height, and `.fit` would collapse to `Color`'s 10pt ideal
            // height. `.fill` takes the larger dimension, which is the column width.
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                } else {
                    placeholder()
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            // Without this the tap target is only the (clipped-away) image bounds.
            .contentShape(.rect(cornerRadius: cornerRadius))
            .task(id: item?.id) {
                image = nil
                guard let item else { return }
                image = await imageLoader.thumbnail(for: item, size: size)
            }
    }
}

extension MediaThumbnail where Placeholder == AnyView {
    /// Standard grey placeholder with a symbol, used by most grid cells.
    static func placeholderFill(systemImage: String) -> AnyView {
        AnyView(
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        )
    }
}
