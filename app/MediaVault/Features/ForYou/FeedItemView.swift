import AVFoundation
import SwiftUI

struct FeedItemView: View {
    let item: MediaItem
    let isActive: Bool

    @Environment(LikesService.self) private var likes
    @Environment(MediaScannerService.self) private var scanner
    @Environment(ImageLoader.self) private var imageLoader
    @Environment(MediaDeletionService.self) private var deletion
    @Environment(LibraryController.self) private var library
    @Environment(ForYouFeedModel.self) private var feed
    @Environment(FeedPlayerPool.self) private var playerPool
    @Environment(OrientationController.self) private var orientation

    @State private var image: UIImage?
    @State private var isLandscapeMedia = false
    @State private var showDeleteConfirmation = false
    @State private var showProfile = false
    @State private var deleteError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch item.mediaType {
            case .image: imageView
            case .video: videoView
            }

            overlay
        }
        .confirmationDialog(
            "Move \"\(item.fileName)\" to Trash?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await delete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is moved to the Trash folder, not erased.")
        }
        .alert("Delete Failed", isPresented: .constant(deleteError != nil)) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $showProfile) {
            if let profile = scanner.profiles.first(where: { $0.id == item.profileID }) {
                NavigationStack {
                    ProfileDetailView(profile: profile)
                }
            }
        }
    }

    // MARK: - Media

    private var imageView: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            image = await imageLoader.fullImage(
                for: item.url,
                maxDimension: ImageLoader.feedImageMaxDimension
            )
            if let image {
                isLandscapeMedia = image.size.width > image.size.height
            }
        }
    }

    private var videoView: some View {
        Group {
            if let player = playerPool.player(for: item) {
                FeedVideoPlayerView(
                    player: player,
                    videoGravity: isLandscapeMedia ? .resizeAspect : .resizeAspectFill
                )
                .ignoresSafeArea()
            } else {
                // Only shows if the user outran the preload window.
                ProgressView().tint(.white)
            }
        }
        .task(id: item.id) {
            isLandscapeMedia = await Self.isLandscape(url: item.url)
        }
    }

    /// Reads the track's display dimensions so landscape video can be letterboxed
    /// instead of being cropped by an aspect-fill gravity.
    private static func isLandscape(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return false }

        let displaySize = naturalSize.applying(transform)
        return abs(displaySize.width) > abs(displaySize.height)
    }

    // MARK: - Overlay

    private var overlay: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            actions
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button {
                showProfile = true
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.profileName)
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text(item.fileName)
                        .font(.caption)
                        .opacity(0.8)
                    if let subfolder = item.subfolder {
                        Text(subfolder)
                            .font(.caption2)
                            .opacity(0.6)
                    }
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open profile \(item.profileName)")

            Spacer()
        }
        .padding(.horizontal)
        .safeAreaPadding(.top)
        .padding(.top, 32)
        .background(
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    private var actions: some View {
        HStack {
            Spacer()
            VStack(spacing: 16) {
                if isLandscapeMedia {
                    circleButton("Rotate to landscape", systemImage: "rotate.right") {
                        orientation.rotateToLandscape()
                    }
                }

                if let rootURL = library.activeRootURL {
                    let isLiked = likes.isLiked(mediaItem: item, rootURL: rootURL)
                    circleButton(
                        isLiked ? "Unlike" : "Like",
                        systemImage: isLiked ? "heart.fill" : "heart",
                        tint: isLiked ? .red : .white
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            likes.toggleLike(mediaItem: item, rootURL: rootURL)
                        }
                    }
                }

                // Delete used to be a hidden long-press on the like button, which is
                // both undiscoverable and easy to trigger by accident.
                Menu {
                    Button("Move to Trash", systemImage: "trash", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                } label: {
                    circleLabel(systemImage: "ellipsis")
                }
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 80)
    }

    private func circleButton(
        _ label: String,
        systemImage: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            circleLabel(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func circleLabel(systemImage: String, tint: Color = .white) -> some View {
        Image(systemName: systemImage)
            .font(.title2)
            .foregroundStyle(tint)
            .padding(12)
            .background(.ultraThinMaterial, in: .circle)
    }

    // MARK: - Actions

    private func delete() async {
        do {
            try await deletion.delete(item, rootURL: library.activeRootURL)
            feed.remove(id: item.id)
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
