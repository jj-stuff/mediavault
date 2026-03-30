import SwiftUI
import AVKit

struct FullScreenMediaView: View {
    let initialItem: MediaItem
    let rootURL: URL?
    @Environment(LikesService.self) private var likesService
    @Environment(MediaScannerService.self) private var scanner
    @Environment(RemoteServerService.self) private var remoteService
    @Environment(\.dismiss) private var dismiss
    @State private var localItems: [MediaItem]
    @State private var currentIndex: Int = 0
    @State private var showOverlay = true
    @State private var showDeleteAlert = false
    @State private var showErrorAlert = false
    @State private var deleteError: String?

    init(items: [MediaItem], initialItem: MediaItem, rootURL: URL?) {
        self.initialItem = initialItem
        self.rootURL = rootURL
        self._localItems = State(initialValue: items)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(localItems.enumerated()), id: \.element.id) { index, item in
                    MediaContentView(item: item, showOverlay: $showOverlay)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showOverlay { overlayControls }
        }
        .onAppear {
            if let idx = localItems.firstIndex(where: { $0.id == initialItem.id }) { currentIndex = idx }
        }
        .statusBarHidden(!showOverlay)
        .preferredColorScheme(.dark)
        .alert("Move to Trash?", isPresented: $showDeleteAlert) {
            Button("Move to Trash", role: .destructive) { Task { await deleteCurrentItem() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if currentIndex < localItems.count {
                Text("\"\(localItems[currentIndex].fileName)\" will be moved to the Trash folder.")
            }
        }
        .alert("Delete Failed", isPresented: $showErrorAlert) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "An unknown error occurred.")
        }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3).fontWeight(.semibold)
                        .foregroundStyle(.white).padding(10).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if currentIndex < localItems.count {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(localItems[currentIndex].profileName).font(.subheadline).fontWeight(.semibold)
                        Text("\(currentIndex + 1) / \(localItems.count)").font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.white)
                }
            }.padding()
            Spacer()
            if currentIndex < localItems.count, let rootURL {
                bottomBar(item: localItems[currentIndex], rootURL: rootURL)
            }
        }
    }

    private func bottomBar(item: MediaItem, rootURL: URL) -> some View {
        HStack(spacing: 16) {
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
            Button { showDeleteAlert = true } label: {
                Image(systemName: "trash")
                    .font(.title2).foregroundStyle(.white)
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

    // MARK: - Delete logic

    private func deleteCurrentItem() async {
        guard currentIndex < localItems.count else { return }
        let item = localItems[currentIndex]

        do {
            if item.url.isFileURL {
                guard let rootURL else { return }
                try moveToTrash(item: item, rootURL: rootURL)
            } else {
                // Remote: extract relative path from the full file URL
                guard let filesBase = remoteService.filesBaseURL else { return }
                let baseStr = filesBase.absoluteString.hasSuffix("/")
                    ? filesBase.absoluteString
                    : filesBase.absoluteString + "/"
                let itemStr = item.url.absoluteString
                guard itemStr.hasPrefix(baseStr) else { return }
                let path = String(itemStr.dropFirst(baseStr.count))
                try await remoteService.deleteItem(path: path)
            }

            scanner.removeItem(id: item.id)

            localItems.remove(at: currentIndex)
            if localItems.isEmpty {
                dismiss()
            } else if currentIndex >= localItems.count {
                currentIndex = localItems.count - 1
            }
        } catch {
            deleteError = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func moveToTrash(item: MediaItem, rootURL: URL) throws {
        let fm = FileManager.default
        let trashFolder = rootURL.appendingPathComponent("Trash")
        if !fm.fileExists(atPath: trashFolder.path) {
            try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true, attributes: nil)
        }
        var dest = trashFolder.appendingPathComponent(item.fileName)
        if fm.fileExists(atPath: dest.path) {
            let base = item.url.deletingPathExtension().lastPathComponent
            let ext  = item.url.pathExtension
            dest = trashFolder.appendingPathComponent("\(base)_\(Int(Date().timeIntervalSince1970)).\(ext)")
        }
        try fm.moveItem(at: item.url, to: dest)
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
        if fileURL.scheme == "http" || fileURL.scheme == "https" {
            if let data = try? await URLSession.shared.data(from: fileURL).0 {
                image = UIImage(data: data)
            }
        } else {
            image = await { @concurrent () async -> UIImage? in
                return Self.downsampledImage(url: fileURL, maxDimension: 3000)
            }()
        }
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
