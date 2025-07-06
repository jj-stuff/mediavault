import SwiftUI
import AVKit

// MARK: - Main App
@main
struct MediaBrowserApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Data Models
struct User: Identifiable, Codable {
    let id = UUID()
    let username: String
    let avatar: String?
    let mediaCount: Int
    
    enum CodingKeys: String, CodingKey {
        case username, avatar, mediaCount
    }
}

struct MediaItem: Identifiable, Codable {
    let id = UUID()
    let name: String
    let path: String
    let url: String
    let size: Int
    let type: String
    let username: String?
    
    var fullURL: String {
        return "\(NetworkManager.shared.baseURL)\(url)"
    }
    
    var isVideo: Bool {
        ["mp4", "mov", "avi", "webm"].contains(type)
    }
    
    var uniqueID: String {
        return "\(username ?? "unknown")_\(name)"
    }
    
    enum CodingKeys: String, CodingKey {
        case name, path, url, size, type, username
    }
}

// MARK: - Favorites Manager
class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()
    @Published var favoriteIDs: Set<String> = []
    
    private let favoritesKey = "UserFavorites"
    
    init() {
        loadFavorites()
    }
    
    func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            favoriteIDs = decoded
        }
    }
    
    func saveFavorites() {
        if let encoded = try? JSONEncoder().encode(favoriteIDs) {
            UserDefaults.standard.set(encoded, forKey: favoritesKey)
        }
    }
    
    func toggleFavorite(_ item: MediaItem) {
        if favoriteIDs.contains(item.uniqueID) {
            favoriteIDs.remove(item.uniqueID)
        } else {
            favoriteIDs.insert(item.uniqueID)
        }
        saveFavorites()
    }
    
    func isFavorite(_ item: MediaItem) -> Bool {
        return favoriteIDs.contains(item.uniqueID)
    }
}

// MARK: - Network Manager
class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    @Published var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: "ServerURL")
        }
    }
    
    @Published var users: [User] = []
    @Published var feedItems: [MediaItem] = []
    @Published var isLoading = false
    
    init() {
        self.baseURL = UserDefaults.standard.string(forKey: "ServerURL") ?? "http://192.168.1.123:3000"
    }
    
    func fetchUsers() async {
        await MainActor.run {
            isLoading = true
        }
        defer {
            Task { @MainActor in
                isLoading = false
            }
        }
        
        let urlString = "\(baseURL)/api/users"
        guard let url = URL(string: urlString) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decodedResponse = try JSONDecoder().decode(UsersResponse.self, from: data)
            
            // Fetch user details for each user
            var userDetails: [User] = []
            for username in decodedResponse.users {
                if let user = await fetchUserProfile(username: username) {
                    userDetails.append(user)
                }
            }
            
            await MainActor.run {
                self.users = userDetails
            }
        } catch {
            print("Error fetching users: \(error)")
        }
    }
    
    func fetchUserProfile(username: String) async -> User? {
        guard let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/users/\(encodedUsername)") else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let profileResponse = try JSONDecoder().decode(UserProfileResponse.self, from: data)
            return profileResponse.user
        } catch {
            print("Error fetching user profile for \(username): \(error)")
            return nil
        }
    }
    
    func fetchUserMedia(username: String, groupByType: Bool = true) async -> [String: [MediaItem]] {
        guard let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/users/\(encodedUsername)/media?groupByType=\(groupByType)") else { return [:] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(UserMediaResponse.self, from: data)
            return response.media ?? [:]
        } catch {
            print("Error fetching user media: \(error)")
            return [:]
        }
    }
    
    func fetchRandomFeed(limit: Int = 30, mediaType: String? = nil) async {
        var urlString = "\(baseURL)/api/feed/random?limit=\(limit)"
        if let type = mediaType {
            urlString += "&type=\(type)"
        }
        
        guard let url = URL(string: urlString) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(FeedResponse.self, from: data)
            
            await MainActor.run {
                self.feedItems = response.media
            }
        } catch {
            print("Error fetching feed: \(error)")
        }
    }
}

// MARK: - Response Types
struct UsersResponse: Codable {
    let success: Bool
    let users: [String]
}

struct UserProfileResponse: Codable {
    let success: Bool
    let user: User
}

struct UserMediaResponse: Codable {
    let success: Bool
    let media: [String: [MediaItem]]?
}

struct FeedResponse: Codable {
    let success: Bool
    let media: [MediaItem]
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @StateObject private var favoritesManager = FavoritesManager.shared
    @State private var selectedTab = 1
    
    var body: some View {
        TabView(selection: $selectedTab) {
            UsersListView()
                .tabItem {
                    Image(systemName: "person.3.fill")
                    Text("Users")
                }
                .tag(0)
            
            FeedView()
                .tabItem {
                    Image(systemName: "play.rectangle.fill")
                    Text("For You")
                }
                .tag(1)
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(2)
        }
        .environmentObject(favoritesManager)
    }
}

// MARK: - Users List View
struct UsersListView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @State private var searchText = ""
    
    var filteredUsers: [User] {
        if searchText.isEmpty {
            return networkManager.users
        } else {
            return networkManager.users.filter { $0.username.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        NavigationStack {
            List(filteredUsers) { user in
                NavigationLink(destination: UserProfileView(user: user)) {
                    HStack {
                        // User Avatar
                        AsyncImage(url: URL(string: user.avatar != nil ? "\(networkManager.baseURL)\(user.avatar!)" : "")) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                        
                        VStack(alignment: .leading) {
                            Text(user.username)
                                .font(.headline)
                            Text("\(user.mediaCount) media files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Users")
            .searchable(text: $searchText, prompt: "Search users")
            .refreshable {
                await networkManager.fetchUsers()
            }
            .task {
                await networkManager.fetchUsers()
            }
        }
    }
}

// MARK: - Feed View (TikTok-style)
struct FeedView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject var favoritesManager: FavoritesManager
    @State private var currentIndex = 0
    @State private var mediaFilter: MediaFilter = .all
    @State private var isLoading = false
    
    enum MediaFilter: String, CaseIterable {
        case all = "All"
        case photos = "Photos"
        case videos = "Videos"
        
        var apiValue: String? {
            switch self {
            case .all: return nil
            case .photos: return "image"
            case .videos: return "video"
            }
        }
    }
    
    var body: some View {
        ZStack {
            if networkManager.feedItems.isEmpty {
                ProgressView()
                    .scaleEffect(1.5)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(networkManager.feedItems.enumerated()), id: \.element.id) { index, item in
                            FeedItemView(item: item)
                                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                                .onAppear {
                                    // Load more when reaching end
                                    if index == networkManager.feedItems.count - 5 && !isLoading {
                                        Task {
                                            isLoading = true
                                            await networkManager.fetchRandomFeed(mediaType: mediaFilter.apiValue)
                                            isLoading = false
                                        }
                                    }
                                }
                        }
                    }
                }
                .scrollTargetBehavior(.paging)
                .ignoresSafeArea()
            }
            
            // Filter buttons at top
            VStack {
                HStack {
                    ForEach(MediaFilter.allCases, id: \.self) { filter in
                        Button(action: {
                            mediaFilter = filter
                            Task {
                                await networkManager.fetchRandomFeed(mediaType: filter.apiValue)
                            }
                        }) {
                            Text(filter.rawValue)
                                .font(.system(size: 14, weight: mediaFilter == filter ? .bold : .medium))
                                .foregroundColor(mediaFilter == filter ? .black : .gray)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(mediaFilter == filter ? Color.white : Color.white.opacity(0.3))
                                .cornerRadius(20)
                        }
                    }
                }
                .padding(.top, 60)
                
                Spacer()
            }
        }
        .task {
            await networkManager.fetchRandomFeed(mediaType: mediaFilter.apiValue)
        }
    }
}

// MARK: - Feed Item View
struct FeedItemView: View {
    let item: MediaItem
    @EnvironmentObject var favoritesManager: FavoritesManager
    @State private var showUserProfile = false
    @State private var player: AVPlayer?
    
    var body: some View {
        ZStack {
            Color.black
            
            if item.isVideo {
                VideoPlayerView(url: URL(string: item.fullURL)!, player: $player)
                    .onAppear {
                        player?.play()
                    }
                    .onDisappear {
                        player?.pause()
                    }
            } else {
                AsyncImage(url: URL(string: item.fullURL)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } placeholder: {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            }
            
            // Side buttons
            VStack {
                Spacer()
                
                HStack {
                    Spacer()
                    
                    VStack(spacing: 20) {
                        // User profile button
                        if let username = item.username {
                            Button(action: {
                                showUserProfile = true
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 44))
                                        .foregroundColor(.white)
                                        .shadow(radius: 3)
                                }
                            }
                            .sheet(isPresented: $showUserProfile) {
                                if let user = NetworkManager.shared.users.first(where: { $0.username == username }) {
                                    NavigationStack {
                                        UserProfileView(user: user)
                                    }
                                }
                            }
                        }
                        
                        // Like button
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                favoritesManager.toggleFavorite(item)
                            }
                        }) {
                            Image(systemName: favoritesManager.isFavorite(item) ? "heart.fill" : "heart")
                                .font(.system(size: 32))
                                .foregroundColor(favoritesManager.isFavorite(item) ? .red : .white)
                                .scaleEffect(favoritesManager.isFavorite(item) ? 1.2 : 1.0)
                                .shadow(radius: 3)
                        }
                        
                        // Bookmark button
                        Button(action: {}) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .shadow(radius: 3)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 100)
                }
            }
            
            // Username at bottom
            if let username = item.username {
                VStack {
                    Spacer()
                    HStack {
                        Text("@\(username)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .shadow(radius: 3)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 60)
                }
            }
        }
    }
}

// MARK: - Video Player View (Fixed aspect ratio)
struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var player: AVPlayer?
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 1.0
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect // Ensures video fits without stretching
        
        // Auto loop
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }
        
        DispatchQueue.main.async {
            self.player = player
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - User Profile View
struct UserProfileView: View {
    let user: User
    @EnvironmentObject var favoritesManager: FavoritesManager
    @State private var selectedTab = "photos"
    @State private var userMedia: [String: [MediaItem]] = [:]
    @State private var allMediaItems: [MediaItem] = []
    @State private var isLoading = true
    @State private var headerOffset: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Profile Header (scrolls away)
                        GeometryReader { geo in
                            VStack(spacing: 16) {
                                AsyncImage(url: URL(string: user.avatar != nil ? "\(NetworkManager.shared.baseURL)\(user.avatar!)" : "")) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 80))
                                        .foregroundColor(.gray)
                                }
                                .frame(width: 100, height: 100)
                                .clipShape(Circle())
                                
                                Text(user.username)
                                    .font(.title2)
                                    .bold()
                                
                                Text("\(user.mediaCount) media files")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: geometry.size.width)
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
                        
                        // Sticky Tab Selection
                        Picker("Media Type", selection: $selectedTab) {
                            Text("Photos").tag("photos")
                            Text("Videos").tag("videos")
                            Text("Favorites").tag("favorites")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemBackground))
                        
                        // Media Grid
                        if isLoading {
                            ProgressView()
                                .padding(.top, 50)
                        } else {
                            MediaGridView(mediaItems: currentMediaItems)
                                .padding(.top, 8)
                        }
                    }
                }
                
                // Sticky navigation title (appears when scrolled)
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
            isLoading = true
            userMedia = await NetworkManager.shared.fetchUserMedia(username: user.username)
            
            // Collect all media items
            allMediaItems = userMedia.values.flatMap { $0 }
            
            isLoading = false
        }
    }
    
    var currentMediaItems: [MediaItem] {
        switch selectedTab {
        case "photos":
            return ["jpg", "jpeg", "png", "gif", "webp"].flatMap { userMedia[$0] ?? [] }
        case "videos":
            return ["mp4", "mov", "avi", "webm"].flatMap { userMedia[$0] ?? [] }
        case "favorites":
            return allMediaItems.filter { favoritesManager.isFavorite($0) }
        default:
            return []
        }
    }
}

// MARK: - Media Grid View
struct MediaGridView: View {
    let mediaItems: [MediaItem]
    let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
                MediaThumbnailView(item: item, allItems: mediaItems, currentIndex: index)
            }
        }
    }
}

// MARK: - Media Thumbnail View (Fixed cropping)
struct MediaThumbnailView: View {
    let item: MediaItem
    let allItems: [MediaItem]
    let currentIndex: Int
    @State private var showFullScreen = false
    @State private var thumbnail: UIImage?
    
    var body: some View {
        Button(action: {
            showFullScreen = true
        }) {
            ZStack {
                if item.isVideo {
                    // Video thumbnail
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: UIScreen.main.bounds.width / 3 - 4, height: UIScreen.main.bounds.width / 3 - 4)
                            .clipped()
                    } else {
                        Rectangle()
                            .foregroundColor(.gray.opacity(0.3))
                            .frame(width: UIScreen.main.bounds.width / 3 - 4, height: UIScreen.main.bounds.width / 3 - 4)
                            .onAppear {
                                generateThumbnail()
                            }
                    }
                } else {
                    // Image thumbnail - cropped to square
                    AsyncImage(url: URL(string: item.fullURL)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: UIScreen.main.bounds.width / 3 - 4, height: UIScreen.main.bounds.width / 3 - 4)
                            .clipped()
                    } placeholder: {
                        Rectangle()
                            .foregroundColor(.gray.opacity(0.3))
                            .frame(width: UIScreen.main.bounds.width / 3 - 4, height: UIScreen.main.bounds.width / 3 - 4)
                    }
                }
                
                if item.isVideo {
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
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            MediaGalleryView(items: allItems, startIndex: currentIndex)
        }
    }
    
    func generateThumbnail() {
        guard let url = URL(string: item.fullURL) else { return }
        
        Task {
            let asset = AVAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width: 300, height: 300)
            
            do {
                let cgImage = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
                await MainActor.run {
                    self.thumbnail = UIImage(cgImage: cgImage)
                }
            } catch {
                print("Error generating thumbnail: \(error)")
            }
        }
    }
}

// MARK: - Media Gallery View (Swipeable with video support)
struct MediaGalleryView: View {
    let items: [MediaItem]
    let startIndex: Int
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var favoritesManager: FavoritesManager
    @State private var currentIndex: Int
    @State private var players: [Int: AVPlayer] = [:]
    
    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: startIndex)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ZStack {
                        if item.isVideo {
                            VideoPlayerView(url: URL(string: item.fullURL)!, player: binding(for: index))
                                .onAppear {
                                    players[index]?.play()
                                }
                                .onDisappear {
                                    players[index]?.pause()
                                }
                        } else {
                            AsyncImage(url: URL(string: item.fullURL)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } placeholder: {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(PageTabViewStyle())
            .ignoresSafeArea()
            
            // Top controls
            VStack {
                HStack {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding()
                    
                    Spacer()
                    
                    // Like button
                    if currentIndex < items.count {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                favoritesManager.toggleFavorite(items[currentIndex])
                            }
                        }) {
                            Image(systemName: favoritesManager.isFavorite(items[currentIndex]) ? "heart.fill" : "heart")
                                .font(.system(size: 24))
                                .foregroundColor(favoritesManager.isFavorite(items[currentIndex]) ? .red : .white)
                                .padding()
                        }
                    }
                }
                
                Spacer()
                
                // Page indicator
                Text("\(currentIndex + 1) / \(items.count)")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(20)
                    .padding(.bottom)
            }
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            // Pause old video
            players[oldValue]?.pause()
            // Play new video
            players[newValue]?.play()
        }
    }
    
    func binding(for index: Int) -> Binding<AVPlayer?> {
        Binding(
            get: { players[index] },
            set: { players[index] = $0 }
        )
    }
}

// MARK: - Settings View (with editable server URL)
struct SettingsView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @State private var serverURL: String = ""
    @State private var showingAlert = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    HStack {
                        Text("Current URL")
                        Spacer()
                        Text(networkManager.baseURL)
                            .foregroundColor(.secondary)
                            .font(.system(.caption, design: .monospaced))
                    }
                    
                    HStack {
                        TextField("New Server URL", text: $serverURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        Button("Update") {
                            if !serverURL.isEmpty {
                                networkManager.baseURL = serverURL
                                serverURL = ""
                                showingAlert = true
                            }
                        }
                        .foregroundColor(.blue)
                    }
                }
                
                Section("Cache") {
                    Button("Clear Image Cache") {
                        URLCache.shared.removeAllCachedResponses()
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.1")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Server Updated", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Server URL has been updated. You may need to refresh the user list.")
            }
            .onAppear {
                serverURL = networkManager.baseURL
            }
        }
    }
}
