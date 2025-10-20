import SwiftUI
import AVKit

struct FeedItemView: View {
    let item: MediaItem
    let isVisible: Bool

    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var deletionManager: DeletionManager

    @State private var showUserProfile = false
    @State private var player: AVPlayer?
    @State private var isLandscape = false
    @State private var aspectMode: ContentMode = .fit
    @State private var isPlayerReady = false

    @AppStorage("skipDuration") private var skipDuration: Double = 5.0
    @AppStorage("useLocalMode") private var useLocalMode = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            mediaContent

            if !isLandscape {
                overlayControls
            }

            if let username = item.username, !isLandscape {
                usernameBadge(username: username)
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        if item.isVideo, let mediaURL = item.resolvedURL {
            GeometryReader { geometry in
                EnhancedVideoPlayerView(
                    url: mediaURL,
                    player: $player,
                    skipDuration: skipDuration,
                    isLandscape: $isLandscape,
                    shouldPlay: isVisible,
                    onPlayerReady: {
                        isPlayerReady = true
                        if isVisible {
                            player?.play()
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
                .onDisappear {
                    player?.pause()
                    player?.seek(to: .zero)
                    isLandscape = false
                    isPlayerReady = false
                }
                    .onChange(of: isVisible) { _, newValue in
                        guard isPlayerReady else { return }
                        if newValue {
                            player?.play()
                        } else {
                        player?.pause()
                    }
                }
            }
            .ignoresSafeArea()
        } else {
            ZoomableImageView(url: item.fullURL, aspectMode: $aspectMode)
        }
    }

    private var overlayControls: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                controlStack
                    .padding(.trailing, 16)
                    .padding(.bottom, 160)
            }
        }
    }

    private var controlStack: some View {
        VStack(spacing: 20) {
            if let username = item.username, !useLocalMode {
                Button { showUserProfile = true } label: {
                    userAvatar(username: username)
                }
                .shadow(radius: 3)
                .sheet(isPresented: $showUserProfile) {
                    if let user = NetworkManager.shared.users.first(where: { $0.username == username }) {
                        NavigationStack {
                            UserProfileView(user: user)
                                .environmentObject(favoritesManager)
                                .environmentObject(deletionManager)
                        }
                    }
                }
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    favoritesManager.toggleFavorite(item)
                }
            } label: {
                Image(systemName: favoritesManager.isFavorite(item) ? "heart.fill" : "heart")
                    .font(.system(size: 32))
                    .foregroundColor(favoritesManager.isFavorite(item) ? .red : .white)
                    .scaleEffect(favoritesManager.isFavorite(item) ? 1.2 : 1.0)
                    .shadow(radius: 3)
            }

            if item.isVideo {
                Button {
                    withAnimation {
                        isLandscape.toggle()
                    }
                } label: {
                    Image(systemName: isLandscape ? "rotate.left" : "rotate.right")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                        .padding(8)
                        .background(isLandscape ? Color.white.opacity(0.2) : Color.clear)
                        .clipShape(Circle())
                }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        aspectMode = (aspectMode == .fit) ? .fill : .fit
                    }
                } label: {
                    Image(systemName: aspectMode == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                }
            }

            Button {
                Task {
                    await deletionManager.toggleDeletion(item)
                }
            } label: {
                if useLocalMode {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.4))
                        .shadow(radius: 3)
                } else if deletionManager.isUpdating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: deletionManager.isMarkedForDeletion(item) ? "trash.fill" : "trash")
                        .font(.system(size: 28))
                        .foregroundColor(deletionManager.isMarkedForDeletion(item) ? .red : .white)
                        .shadow(radius: 3)
                }
            }
            .disabled(useLocalMode || deletionManager.isUpdating)
        }
    }

    private func usernameBadge(username: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Text("@\(username)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(radius: 3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 140)
        }
    }

    @ViewBuilder
    private func userAvatar(username: String) -> some View {
        if
            let user = NetworkManager.shared.users.first(where: { $0.username == username }),
            let avatar = user.avatar,
            let url = URL(string: "\(NetworkManager.shared.baseURL)\(avatar)")
        {
            CachedAsyncImage(url: url) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
        } else {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.white)
        }
    }
}
