import SwiftUI
import AVFoundation

struct ForYouTab: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LikesService.self) private var likesService
    @State private var feedItems: [MediaItem] = []
    let rootURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if scanner.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Content", systemImage: "play.square.stack")
                        .foregroundStyle(.white)
                } description: {
                    Text("Select a folder in Settings to start discovering content.")
                        .foregroundStyle(.gray)
                }
            } else if feedItems.isEmpty {
                ProgressView("Building your feed...").foregroundStyle(.white)
            } else {
                feedView
            }
        }
        .onAppear {
            if feedItems.isEmpty && !scanner.profiles.isEmpty {
                feedItems = ForYouAlgorithm.generateFeed(from: scanner.profiles)
            }
        }
        .onChange(of: scanner.profiles) { _, newProfiles in
            if !newProfiles.isEmpty && feedItems.isEmpty {
                feedItems = ForYouAlgorithm.generateFeed(from: newProfiles)
            }
        }
    }

    private var feedView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(feedItems.enumerated()), id: \.element.id) { index, item in
                    FeedItemView(item: item, rootURL: rootURL)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .onAppear { loadMoreIfNeeded(index: index) }
                }
            }
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.never)
        .ignoresSafeArea()
    }

    private func loadMoreIfNeeded(index: Int) {
        if index >= feedItems.count - 10 {
            let more = ForYouAlgorithm.generateNextBatch(from: scanner.profiles, currentFeed: feedItems)
            feedItems.append(contentsOf: more)
        }
    }
}

struct FeedItemView: View {
    let item: MediaItem
    let rootURL: URL?
    @Environment(LikesService.self) private var likesService
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var isLandscapeVideo = false
    @State private var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch item.mediaType {
            case .image: imageView
            case .video: videoView
            }

            overlayInfo
        }
    }

    // MARK: Image

    private var imageView: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
            }
        }
        .task {
            let url = item.url
            if url.scheme == "http" || url.scheme == "https" {
                if let data = try? await URLSession.shared.data(from: url).0 {
                    image = UIImage(data: data)
                }
            } else {
                image = await { @concurrent () async -> UIImage? in
                    Self.downsampledImage(url: url, maxDimension: 2000)
                }()
            }
        }
    }

    nonisolated private static func downsampledImage(url: URL, maxDimension: CGFloat) -> UIImage? {
        let sourceOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Video

    private var videoView: some View {
        Group {
            if let player {
                FeedVideoPlayerView(player: player, shouldPlay: true, videoGravity: videoGravity)
                    .ignoresSafeArea()
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard player == nil else { return }
            let url = item.url
            player = AVPlayer(url: url)
            Task {
                let asset = AVURLAsset(url: url)
                guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
                let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let displaySize = naturalSize.applying(transform)
                if abs(displaySize.width) > abs(displaySize.height) {
                    isLandscapeVideo = true
                    videoGravity = .resizeAspect
                }
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            isLandscapeVideo = false
            videoGravity = .resizeAspectFill
        }
    }

    // MARK: Overlay

    private var overlayInfo: some View {
        VStack(spacing: 0) {
            // Info at top-right
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.profileName).font(.subheadline).fontWeight(.bold)
                    Text(item.fileName).font(.caption).opacity(0.8)
                    if let sub = item.subfolder { Text(sub).font(.caption2).opacity(0.6) }
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal)
            .safeAreaPadding(.top)
            .padding(.top, 32)
            .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            // Action buttons on the right, above the tab bar
            HStack {
                Spacer()
                VStack(spacing: 16) {
                    if isLandscapeVideo {
                        Button {
                            videoGravity = videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
                        } label: {
                            Image(systemName: videoGravity == .resizeAspect
                                  ? "arrow.up.left.and.arrow.down.right"
                                  : "arrow.down.right.and.arrow.up.left")
                                .font(.title3).foregroundStyle(.white)
                                .padding(10).background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    if let rootURL {
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
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 80)
        }
    }
}
