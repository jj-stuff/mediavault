import SwiftUI

/// A square thumbnail that loads itself from the shared `ImageLoader`.
///
/// Four different grid cells each carried their own `@State` image plus a `.task`
/// that called the loader; this is that pattern, written once. Keying the task on
/// the item's id matters in a lazy grid: SwiftUI reuses the view's identity as rows
/// scroll, so without it a recycled cell keeps showing the previous item's picture.
struct MediaThumbnail<Placeholder: View>: View {
    let item: MediaItem?
    var size: CGSize = ImageLoader.thumbnailSize
    var cornerRadius: CGFloat = 0
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(ImageLoader.self) private var imageLoader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .accessibilityHidden(true)
            } else {
                placeholder()
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
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
