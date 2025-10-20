import SwiftUI

struct UserProfileView: View {
    let user: User

    @EnvironmentObject private var favoritesManager: FavoritesManager

    @State private var selectedTab = MediaCategory.photos
    @State private var userMedia: [String: [MediaItem]] = [:]
    @State private var allMediaItems: [MediaItem] = []
    @State private var isLoading = true
    @State private var headerOffset: CGFloat = 0

    private let networkManager = NetworkManager.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        profileHeader(width: geometry.size.width)

                        Picker("Media Type", selection: $selectedTab) {
                            ForEach(MediaCategory.allCases, id: \.self) { category in
                                Text(category.title).tag(category)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemBackground))

                        if isLoading {
                            ProgressView()
                                .padding(.top, 50)
                        } else {
                            MediaGridView(mediaItems: currentMediaItems)
                                .padding(.top, 8)
                        }
                    }
                }

                if headerOffset < -100 {
                    HStack {
                        Text(user.username)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(UIColor.systemBackground).opacity(0.95))
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: headerOffset)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMedia()
        }
    }

    private func profileHeader(width: CGFloat) -> some View {
        GeometryReader { geo in
            VStack(spacing: 16) {
                CachedAsyncImage(
                    url: avatarURL,
                    placeholder: {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                    }
                )
                .frame(width: 100, height: 100)
                .clipShape(Circle())

                Text(user.username)
                    .font(.title2)
                    .bold()

                Text("\(user.mediaCount) media files")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(width: width)
            .padding(.vertical)
            .background(Color(UIColor.systemBackground))
            .offset(y: max(0, -geo.frame(in: .global).minY))
            .onAppear {
                headerOffset = geo.frame(in: .global).minY
            }
            .onChange(of: geo.frame(in: .global).minY) { _, newValue in
                headerOffset = newValue
            }
        }
        .frame(height: 200)
    }

    private func loadMedia() async {
        isLoading = true
        let media = await networkManager.fetchUserMedia(username: user.username)
        await MainActor.run {
            userMedia = media
            allMediaItems = media.values.flatMap { $0 }
            isLoading = false
        }
    }

    private var avatarURL: URL? {
        guard let avatar = user.avatar else { return nil }
        return URL(string: "\(networkManager.baseURL)\(avatar)")
    }

    private var currentMediaItems: [MediaItem] {
        switch selectedTab {
        case .photos:
            return ["jpg", "jpeg", "png", "gif", "webp"].flatMap { userMedia[$0] ?? [] }
        case .videos:
            return ["mp4", "mov", "avi", "webm"].flatMap { userMedia[$0] ?? [] }
        case .favorites:
            return allMediaItems.filter { favoritesManager.isFavorite($0) }
        }
    }
}

private enum MediaCategory: String, CaseIterable {
    case photos
    case videos
    case favorites

    var title: String {
        switch self {
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .favorites: return "Favorites"
        }
    }
}
