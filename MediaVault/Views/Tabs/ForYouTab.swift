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
                    FeedItemView(item: item, rootURL: rootURL, onDelete: { id in
                        feedItems.removeAll { $0.id == id }
                    })
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
    let onDelete: (UUID) -> Void

    @Environment(LikesService.self) private var likesService
    @Environment(MediaScannerService.self) private var scanner
    @Environment(RemoteServerService.self) private var remoteService

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var isLandscapeVideo = false
    @State private var isLandscapeImage = false
    @State private var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    @State private var showDeleteAlert = false
    @State private var showErrorAlert = false
    @State private var deleteError: String?
    @State private var showProfile = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch item.mediaType {
            case .image: imageView
            case .video: videoView
            }

            overlayInfo
        }
        .onDisappear { restorePortrait() }
        .alert("Move to Trash?", isPresented: $showDeleteAlert) {
            Button("Move to Trash", role: .destructive) { Task { await deleteItem() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(item.fileName)\" will be moved to the Trash folder.")
        }
        .alert("Delete Failed", isPresented: $showErrorAlert) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $showProfile) {
            if let profile = scanner.profiles.first(where: { $0.id == item.profileID }) {
                NavigationStack {
                    ProfileDetailView(profile: profile, rootURL: rootURL)
                }
            }
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
            var loaded: UIImage?
            if url.scheme == "http" || url.scheme == "https" {
                if let data = try? await URLSession.shared.data(from: url).0 {
                    loaded = UIImage(data: data)
                }
            } else {
                loaded = await { @concurrent () async -> UIImage? in
                    Self.downsampledImage(url: url, maxDimension: 2000)
                }()
            }
            image = loaded
            if let img = loaded {
                isLandscapeImage = img.size.width > img.size.height
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
            // Profile name at top-left — tap to open profile page
            HStack(alignment: .top) {
                Button {
                    showProfile = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.profileName).font(.subheadline).fontWeight(.bold)
                        Text(item.fileName).font(.caption).opacity(0.8)
                        if let sub = item.subfolder { Text(sub).font(.caption2).opacity(0.6) }
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal)
            .safeAreaPadding(.top)
            .padding(.top, 32)
            .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            // Action buttons on the right side
            HStack {
                Spacer()
                VStack(spacing: 16) {
                    // Rotate-to-landscape button for landscape content
                    if isLandscapeVideo || isLandscapeImage {
                        Button { rotateToLandscape() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.title3).foregroundStyle(.white)
                                .padding(10).background(.ultraThinMaterial, in: Circle())
                        }
                    }

                    // Like button — tap to like, long-press for delete
                    if let rootURL {
                        let isLiked = likesService.isLiked(mediaItem: item, rootURL: rootURL)
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isLiked ? .red : .white)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    likesService.toggleLike(mediaItem: item, rootURL: rootURL)
                                }
                            }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                showDeleteAlert = true
                            }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 80)
        }
    }

    // MARK: Rotate

    private func rotateToLandscape() {
        AppDelegate.orientationLock = .landscape
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscape)
        try? windowScene.requestGeometryUpdate(preferences)
    }

    private func restorePortrait() {
        AppDelegate.orientationLock = .portrait
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
        try? windowScene.requestGeometryUpdate(preferences)
    }

    // MARK: Delete

    private func deleteItem() async {
        do {
            if item.url.isFileURL {
                guard let rootURL else { return }
                try moveToTrash(item: item, rootURL: rootURL)
            } else {
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
            onDelete(item.id)
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
