import SwiftUI
import AVKit
import UIKit

struct MediaGridView: View {
    let mediaItems: [MediaItem]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
                MediaThumbnailView(item: item, allItems: mediaItems, currentIndex: index)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct MediaThumbnailView: View {
    let item: MediaItem
    let allItems: [MediaItem]
    let currentIndex: Int

    @State private var showFullScreen = false
    @State private var thumbnail: UIImage?

    private var tileSize: CGFloat {
        (UIScreen.main.bounds.width / 3) - 4
    }

    var body: some View {
        Button {
            showFullScreen = true
        } label: {
            ZStack {
                thumbnailContent
                    .frame(width: tileSize, height: tileSize)
                    .clipped()
                    .background(Color.gray.opacity(0.3))
                    .contentShape(Rectangle())

                if item.isVideo {
                    videoBadge
                }
            }
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showFullScreen) {
            MediaGalleryView(items: allItems, startIndex: currentIndex)
        }
        .onAppear {
            prepareVideoThumbnailIfNeeded()
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if item.isVideo {
            if let thumbnailURLString = item.thumbnailURL, let url = URL(string: thumbnailURLString) {
                CachedAsyncImage(url: url) {
                    placeholderView
                }
                .scaledToFill()
            } else if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderView
            }
        } else if let url = URL(string: item.fullURL) {
            CachedAsyncImage(url: url) {
                placeholderView
            }
            .scaledToFill()
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        Rectangle()
            .foregroundColor(.gray.opacity(0.3))
    }

    private var videoBadge: some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundColor(.white)
                    .font(.caption)
                    .padding(4)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Circle())
                    .padding(4)
            }
            Spacer()
        }
    }

    private func prepareVideoThumbnailIfNeeded() {
        guard item.isVideo, thumbnail == nil else { return }

        if let cached = ImageCache.shared.image(forKey: thumbnailCacheKey) {
            thumbnail = cached
            return
        }

        guard let url = URL(string: item.fullURL) else { return }

        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 300)

            do {
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                let uiImage = UIImage(cgImage: cgImage)
                ImageCache.shared.store(image: uiImage, forKey: thumbnailCacheKey)

                await MainActor.run {
                    thumbnail = uiImage
                }
            } catch {
                print("Error generating thumbnail: \(error)")
            }
        }
    }

    private var thumbnailCacheKey: String {
        "video-thumb-\(item.uniqueID)"
    }
}

struct MediaGalleryView: View {
    let items: [MediaItem]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var currentIndex: Int
    @State private var players: [Int: AVPlayer] = [:]
    @State private var aspectModes: [Int: ContentMode] = [:]
    @State private var isLandscape = false

    @AppStorage("skipDuration") private var skipDuration: Double = 5.0

    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ZStack {
                        if item.isVideo {
                            GeometryReader { geometry in
                                EnhancedVideoPlayerView(
                                    url: URL(string: item.fullURL)!,
                                    player: bindingForPlayer(at: index),
                                    skipDuration: skipDuration,
                                    isLandscape: $isLandscape,
                                    shouldPlay: currentIndex == index,
                                    onPlayerReady: {
                                        if currentIndex == index {
                                            players[index]?.play()
                                        }
                                    }
                                )
                                .frame(
                                    width: isLandscape ? geometry.size.height : geometry.size.width,
                                    height: isLandscape ? geometry.size.width : geometry.size.height
                                )
                                .rotationEffect(.degrees(isLandscape ? 90 : 0))
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                .animation(.easeInOut(duration: 0.3), value: isLandscape)
                            }
                        } else {
                            ZoomableImageView(
                                url: item.fullURL,
                                aspectMode: bindingForAspectMode(at: index)
                            )
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .ignoresSafeArea()

            if !isLandscape {
                overlayControls
            }
        }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button("Done") {
                    dismiss()
                }
                .foregroundColor(.white)
                .padding()

                Spacer()

                if currentIndex < items.count {
                    controlButtons(for: items[currentIndex])
                }
            }

            Spacer()
        }
    }

    private func controlButtons(for item: MediaItem) -> some View {
        HStack(spacing: 20) {
            if item.isVideo {
                Button {
                    withAnimation {
                        isLandscape.toggle()
                    }
                } label: {
                    Image(systemName: isLandscape ? "rotate.left" : "rotate.right")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        let current = aspectModes[currentIndex] ?? .fit
                        aspectModes[currentIndex] = current == .fit ? .fill : .fit
                    }
                } label: {
                    Image(systemName: (aspectModes[currentIndex] ?? .fit) == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }
            }

            Button {
                Task {
                    await deletionManager.toggleDeletion(item)
                }
            } label: {
                if deletionManager.isUpdating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: deletionManager.isMarkedForDeletion(item) ? "trash.fill" : "trash")
                        .font(.system(size: 24))
                        .foregroundColor(deletionManager.isMarkedForDeletion(item) ? .red : .white)
                }
            }
            .disabled(deletionManager.isUpdating)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    favoritesManager.toggleFavorite(item)
                }
            } label: {
                Image(systemName: favoritesManager.isFavorite(item) ? "heart.fill" : "heart")
                    .font(.system(size: 24))
                    .foregroundColor(favoritesManager.isFavorite(item) ? .red : .white)
            }
        }
        .padding(.trailing, 24)
    }

    private func bindingForPlayer(at index: Int) -> Binding<AVPlayer?> {
        Binding(
            get: { players[index] },
            set: { players[index] = $0 }
        )
    }

    private func bindingForAspectMode(at index: Int) -> Binding<ContentMode> {
        Binding(
            get: { aspectModes[index] ?? .fit },
            set: { aspectModes[index] = $0 }
        )
    }
}
