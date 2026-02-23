import SwiftUI
import AVKit

struct FullScreenMediaView: View {
    let items: [MediaItem]
    let initialItem: MediaItem
    let rootURL: URL?
    @Environment(LikesService.self) private var likesService
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var showOverlay = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    MediaContentView(item: item, showOverlay: $showOverlay)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showOverlay { overlayControls }
        }
        .onAppear {
            if let idx = items.firstIndex(where: { $0.id == initialItem.id }) { currentIndex = idx }
        }
        .statusBarHidden(!showOverlay)
        .preferredColorScheme(.dark)
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3).fontWeight(.semibold)
                        .foregroundStyle(.white).padding(10).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if currentIndex < items.count {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(items[currentIndex].profileName).font(.subheadline).fontWeight(.semibold)
                        Text("\(currentIndex + 1) / \(items.count)").font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.white)
                }
            }.padding()
            Spacer()
            if currentIndex < items.count, let rootURL {
                bottomBar(item: items[currentIndex], rootURL: rootURL)
            }
        }
    }

    private func bottomBar(item: MediaItem, rootURL: URL) -> some View {
        HStack(spacing: 20) {
            let isLiked = likesService.isLiked(mediaItem: item, rootURL: rootURL)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    likesService.toggleLike(mediaItem: item, rootURL: rootURL)
                }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.title2).foregroundStyle(isLiked ? .red : .white)
                    .padding(12).background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.fileName).font(.caption2).lineLimit(1)
                if let sub = item.subfolder { Text(sub).font(.caption2).foregroundStyle(.secondary) }
            }.foregroundStyle(.white)
        }
        .padding()
        .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Media Content (Image or Video)

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

// MARK: - Zoomable Image (UIScrollView-based — proper clamp, bounce, gesture passthrough)

struct ZoomableImageView: View {
    let url: URL
    @Binding var showOverlay: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView(image: image, showOverlay: $showOverlay)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
        .task { await loadImage() }
    }

    private func loadImage() async {
        let fileURL = url
        image = await { @concurrent () async -> UIImage? in
            return Self.downsampledImage(url: fileURL, maxDimension: 3000)
        }()
    }

    /// Loads via CGImageSource with downsampling — avoids IOSurface memory errors
    /// that happen when loading multi-megapixel JPEGs directly with UIImage(data:).
    nonisolated private static func downsampledImage(url: URL, maxDimension: CGFloat) -> UIImage? {
        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts as CFDictionary) else {
            return nil
        }
        let downsampleOpts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts as CFDictionary) else {
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
            return img
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Video with EnhancedVideoPlayerView (scrubber, skip zones, speed boost)

struct VideoContentView: View {
    let url: URL
    @State private var player: AVPlayer? = nil
    @State private var isLandscape = false

    var body: some View {
        EnhancedVideoPlayerView(
            url: url,
            player: $player,
            skipDuration: 10,
            isLandscape: $isLandscape,
            shouldPlay: true
        )
        .ignoresSafeArea()
        .onDisappear { player?.pause() }
    }
}
