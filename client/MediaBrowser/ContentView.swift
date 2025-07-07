import SwiftUI
import AVKit
import Foundation
import Combine

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

// MARK: - Deletion Manager
class DeletionManager: ObservableObject {
    static let shared = DeletionManager()
    @Published var markedForDeletion: Set<String> = []
    
    func toggleDeletion(_ item: MediaItem) async {
        let fullPath = "\(NetworkManager.shared.baseURL.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: ":3000", with: ""))\(item.url)"
        
        if markedForDeletion.contains(fullPath) {
            markedForDeletion.remove(fullPath)
        } else {
            markedForDeletion.insert(fullPath)
        }
        
        // Send to server to update deletion list
        await updateDeletionList()
    }
    
    func isMarkedForDeletion(_ item: MediaItem) -> Bool {
        let fullPath = "\(NetworkManager.shared.baseURL.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: ":3000", with: ""))\(item.url)"
        return markedForDeletion.contains(fullPath)
    }
    
    private func updateDeletionList() async {
        // This would send the list to your server endpoint
        // For now, just store locally
        if let encoded = try? JSONEncoder().encode(Array(markedForDeletion)) {
            UserDefaults.standard.set(encoded, forKey: "MarkedForDeletion")
        }
    }
    
    func loadDeletionList() {
        if let data = UserDefaults.standard.data(forKey: "MarkedForDeletion"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            markedForDeletion = Set(decoded)
        }
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
              let url = URL(string: "\(baseURL)/api/users/\(encodedUsername)/media") else { return [:] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Try to decode as flat array first (new server format)
            if let flatResponse = try? JSONDecoder().decode(FlatUserMediaResponse.self, from: data) {
                // Group the flat array by type
                var grouped: [String: [MediaItem]] = [:]
                for item in flatResponse.media {
                    if grouped[item.type] == nil {
                        grouped[item.type] = []
                    }
                    grouped[item.type]?.append(item)
                }
                return grouped
            }
            
            // Fallback to old grouped format
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

struct FlatUserMediaResponse: Codable {
    let success: Bool
    let count: Int
    let media: [MediaItem]
}

struct FeedResponse: Codable {
    let success: Bool
    let media: [MediaItem]
}

// MARK: - Zoomable Image View
struct ZoomableImageView: View {
    let url: String
    @Binding var aspectMode: ContentMode
    
    var body: some View {
        let backgroundColor: Color = .black
        
        ZStack {
            backgroundColor.ignoresSafeArea()
            
            AsyncImage(url: URL(string: url)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: aspectMode)
            } placeholder: {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .black)) //was white
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


// MARK: - Cached Image View
struct CachedAsyncImage: View {
    let url: URL?
    let placeholder: () -> AnyView
    @State private var image: UIImage?
    @State private var isLoading = false
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoading {
                ProgressView()
            } else {
                placeholder()
            }
        }
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        guard let url = url, image == nil, !isLoading else { return }
        
        // Check cache first
        if let cachedImage = ImageCache.shared.getImage(forKey: url.absoluteString) {
            self.image = cachedImage
            return
        }
        
        isLoading = true
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let downloadedImage = UIImage(data: data) {
                    await MainActor.run {
                        self.image = downloadedImage
                        self.isLoading = false
                        ImageCache.shared.setImage(downloadedImage, forKey: url.absoluteString)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Simple Image Cache
class ImageCache {
    static let shared = ImageCache()
    private var cache = NSCache<NSString, UIImage>()
    
    init() {
        cache.countLimit = 100 // Limit number of cached images
        cache.totalCostLimit = 100 * 1024 * 1024 // 100MB limit
    }
    
    func setImage(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.pngData()?.count ?? 0)
    }
    
    func getImage(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }
    
    func clearCache() {
        cache.removeAllObjects()
    }
}
struct ContentView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @StateObject private var favoritesManager = FavoritesManager.shared
    @StateObject private var deletionManager = DeletionManager.shared
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
            
            LikedView()
                .tabItem {
                    Image(systemName: "heart.fill")
                    Text("Liked")
                }
                .tag(2)
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(3)
        }
        .environmentObject(favoritesManager)
        .environmentObject(deletionManager)
        .onAppear {
            deletionManager.loadDeletionList()
        }
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
                NavigationLink(destination: UserProfileView(user: user)
                    .environmentObject(FavoritesManager.shared)
                    .environmentObject(DeletionManager.shared)) {
                    HStack {
                        // User Avatar with caching
                        CachedAsyncImage(
                            url: user.avatar != nil ? URL(string: "\(networkManager.baseURL)\(user.avatar!)") : nil,
                            placeholder: {
                                AnyView(
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 40))
                                        .foregroundColor(.gray)
                                )
                            }
                        )
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
    @State private var visibleIndex: Int? = nil // Track visible item
    @State private var scrollDebounceTimer: Timer?
    
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
                            FeedItemView(item: item, isVisible: visibleIndex == index)
                                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                                .onAppear {
                                    // Debounce scroll to prevent rapid video switching
                                    scrollDebounceTimer?.invalidate()
                                    scrollDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                                        visibleIndex = index
                                    }
                                    
                                    // Load more when reaching last 3 items
                                    if index >= networkManager.feedItems.count - 3 && !isLoading {
                                        Task {
                                            isLoading = true
                                            let currentCount = networkManager.feedItems.count
                                            await networkManager.fetchRandomFeed(mediaType: mediaFilter.apiValue)
                                            
                                            // Append new items instead of replacing
                                            if networkManager.feedItems.count == currentCount {
                                                // If no new items, fetch more
                                                await networkManager.fetchRandomFeed(limit: 50, mediaType: mediaFilter.apiValue)
                                            }
                                            isLoading = false
                                        }
                                    }
                                }
                                .onDisappear {
                                    if visibleIndex == index {
                                        visibleIndex = nil
                                    }
                                }
                        }
                    }
                }
                .scrollTargetBehavior(.paging)
                .ignoresSafeArea()
            }
            
            // Filter buttons at top with rounded shadow
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
                                .foregroundColor(mediaFilter == filter ? .black : .white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(mediaFilter == filter ? Color.white : Color.black.opacity(0.5))
                                .cornerRadius(20)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.4))
                .cornerRadius(25)
                .padding(.horizontal)
                .padding(.top, 55) // Adjusted to be higher but avoid camera island
                
                Spacer()
            }
        }
        .task {
            await networkManager.fetchRandomFeed(mediaType: mediaFilter.apiValue)
        }
    }
}

// MARK: - Liked View (All favorites across users)
struct LikedView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject var favoritesManager: FavoritesManager
    @State private var allLikedItems: [MediaItem] = []
    @State private var isLoading = true
    
    var body: some View {
        NavigationStack {
            if allLikedItems.isEmpty && !isLoading {
                VStack {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No liked items yet")
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView {
                    MediaGridView(mediaItems: allLikedItems)
                        .padding(.top, 8)
                }
            }
        }
        .navigationTitle("Liked")
        .task {
            await loadAllLikedItems()
        }
        .onReceive(favoritesManager.$favoriteIDs) { _ in
            Task {
                await loadAllLikedItems()
            }
        }
    }
    
    private func loadAllLikedItems() async {
        isLoading = true
        var allItems: [MediaItem] = []
        
        await networkManager.fetchUsers()
        
        for user in networkManager.users {
            let userMedia = await networkManager.fetchUserMedia(username: user.username)
            for (_, items) in userMedia {
                for item in items {
                    if favoritesManager.isFavorite(item) {
                        allItems.append(item)
                    }
                }
            }
        }
        
        await MainActor.run {
            self.allLikedItems = allItems
            self.isLoading = false
        }
    }
}

// MARK: - Feed Item View
struct FeedItemView: View {
    let item: MediaItem
    let isVisible: Bool
    @EnvironmentObject var favoritesManager: FavoritesManager
    @EnvironmentObject var deletionManager: DeletionManager
    @State private var showUserProfile = false
    @State private var player: AVPlayer?
    @State private var userAvatar: String?
    @State private var isLandscape = false
    @AppStorage("skipDuration") private var skipDuration: Double = 5.0
    
    // State for image zoom level
    @State private var aspectMode: ContentMode = .fit
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if item.isVideo {
                GeometryReader { geometry in
                    EnhancedVideoPlayerView(url: URL(string: item.fullURL)!, player: $player, skipDuration: skipDuration, isLandscape: $isLandscape)
                        .frame(
                            width: isLandscape ? geometry.size.height : geometry.size.width,
                            height: isLandscape ? geometry.size.width : geometry.size.height
                        )
                        .rotationEffect(.degrees(isLandscape ? 90 : 0))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .animation(.easeInOut(duration: 0.3), value: isLandscape)
                        .onAppear {
                            if isVisible {
                                player?.play()
                            }
                        }
                        .onDisappear {
                            player?.pause()
                            player?.seek(to: .zero)
                            isLandscape = false // Reset rotation when leaving
                        }
                        .onChange(of: isVisible) { _, newValue in
                            if newValue {
                                player?.play()
                            } else {
                                player?.pause()
                            }
                        }
                }
                .ignoresSafeArea()
            } else {
                // Use the new ZoomableImageView, binding its aspectMode
                ZoomableImageView(url: item.fullURL, aspectMode: $aspectMode)
            }
            
            // Side buttons - hide in landscape
            if !isLandscape {
                VStack {
                    Spacer()
                    
                    HStack {
                        Spacer()
                        
                        VStack(spacing: 20) {
                            // User profile button with actual avatar
                            if let username = item.username {
                                Button(action: {
                                    showUserProfile = true
                                }) {
                                    if let user = NetworkManager.shared.users.first(where: { $0.username == username }),
                                       let avatar = user.avatar {
                                        CachedAsyncImage(
                                            url: URL(string: "\(NetworkManager.shared.baseURL)\(avatar)"),
                                            placeholder: {
                                                AnyView(
                                                    Image(systemName: "person.circle.fill")
                                                        .font(.system(size: 44))
                                                        .foregroundColor(.white)
                                                )
                                            }
                                        )
                                        .frame(width: 48, height: 48)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                    } else {
                                        Image(systemName: "person.circle.fill")
                                            .font(.system(size: 44))
                                            .foregroundColor(.white)
                                    }
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
                            
                            // Rotate button for videos OR Zoom button for images
                            if item.isVideo {
                                Button(action: {
                                    withAnimation {
                                        isLandscape.toggle()
                                    }
                                }) {
                                    Image(systemName: isLandscape ? "rotate.left" : "rotate.right")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                        .shadow(radius: 3)
                                        .padding(8)
                                        .background(isLandscape ? Color.white.opacity(0.2) : Color.clear)
                                        .clipShape(Circle())
                                }
                            } else {
                                // Zoom button for images, placed with other controls
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        aspectMode = (aspectMode == .fit) ? .fill : .fit
                                    }
                                }) {
                                    Image(systemName: aspectMode == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 28))
                                        .foregroundColor(.white)
                                        .shadow(radius: 3)
                                }
                            }
                            
                            // Delete mark button
                            Button(action: {
                                Task {
                                    await deletionManager.toggleDeletion(item)
                                }
                            }) {
                                Image(systemName: deletionManager.isMarkedForDeletion(item) ? "trash.fill" : "trash")
                                    .font(.system(size: 28))
                                    .foregroundColor(deletionManager.isMarkedForDeletion(item) ? .red : .white)
                                    .shadow(radius: 3)
                            }
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 160) // Adjusted for new progress bar position
                    }
                }
            }
            
            // Username at bottom (adjusted to not overlap progress bar) - hide in landscape
            if let username = item.username, !isLandscape {
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
                    .padding(.bottom, 140) // Adjusted for new progress bar position
                }
            }
        }
    }
}

// MARK: - Enhanced Video Player View with Progress Bar and Double Tap
struct EnhancedVideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var player: AVPlayer?
    let skipDuration: Double
    @Binding var isLandscape: Bool
    
    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = .black // Black background for letterboxing
        
        // Create player
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 1.0
        
        // Create player view controller
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.showsPlaybackControls = false
        playerViewController.videoGravity = isLandscape ? .resizeAspectFill : .resizeAspect
        
        // Add as child
        container.addChild(playerViewController)
        container.view.addSubview(playerViewController.view)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            playerViewController.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            playerViewController.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        
        playerViewController.didMove(toParent: container)
        
        // Add single tap for play/pause
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        playerViewController.view.addGestureRecognizer(singleTap)
        
        // Create custom controls overlay
        let controlsView = VideoControlsView(player: player, skipDuration: skipDuration)
        controlsView.isHidden = isLandscape
        container.view.addSubview(controlsView)
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor, constant: -60),
            controlsView.heightAnchor.constraint(equalToConstant: 70) // Increased for better touch area
        ])
        
        context.coordinator.controlsView = controlsView
        context.coordinator.playerViewController = playerViewController
        
        // Add gesture recognizers for double tap
        let leftDoubleTap = UITapGestureRecognizer(target: controlsView, action: #selector(VideoControlsView.leftDoubleTapped))
        leftDoubleTap.numberOfTapsRequired = 2
        leftDoubleTap.require(toFail: singleTap)
        
        let rightDoubleTap = UITapGestureRecognizer(target: controlsView, action: #selector(VideoControlsView.rightDoubleTapped))
        rightDoubleTap.numberOfTapsRequired = 2
        rightDoubleTap.require(toFail: singleTap)
        
        // Create left and right tap areas
        let leftTapView = UIView()
        leftTapView.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(leftTapView)
        
        let rightTapView = UIView()
        rightTapView.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(rightTapView)
        
        NSLayoutConstraint.activate([
            leftTapView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            leftTapView.topAnchor.constraint(equalTo: container.view.topAnchor),
            leftTapView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            leftTapView.widthAnchor.constraint(equalTo: container.view.widthAnchor, multiplier: 0.3),
            
            rightTapView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            rightTapView.topAnchor.constraint(equalTo: container.view.topAnchor),
            rightTapView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            rightTapView.widthAnchor.constraint(equalTo: container.view.widthAnchor, multiplier: 0.3)
        ])
        
        leftTapView.addGestureRecognizer(leftDoubleTap)
        rightTapView.addGestureRecognizer(rightDoubleTap)
        
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
        
        return container
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let playerViewController = context.coordinator.playerViewController {
            playerViewController.videoGravity = isLandscape ? .resizeAspectFill : .resizeAspect
        }
        context.coordinator.controlsView?.isHidden = isLandscape
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(player: $player)
    }
    
    class Coordinator: NSObject {
        var player: Binding<AVPlayer?>
        var controlsView: VideoControlsView?
        var playerViewController: AVPlayerViewController?
        
        init(player: Binding<AVPlayer?>) {
            self.player = player
        }
        
        @objc func handleSingleTap() {
            if let player = player.wrappedValue {
                if player.rate == 0 {
                    player.play()
                } else {
                    player.pause()
                }
            }
        }
    }
}

// MARK: - Video Controls View
class VideoControlsView: UIView {
    let player: AVPlayer
    private let skipDuration: Double
    private var progressSlider: UISlider!
    private var timeLabel: UILabel!
    private var timeObserver: Any?
    private var isScrubbing = false
    
    init(player: AVPlayer, skipDuration: Double) {
        self.player = player
        self.skipDuration = skipDuration
        super.init(frame: .zero)
        setupUI()
        startTimeObserver()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }
    
    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.2)
        layer.cornerRadius = 8
        
        // Create a larger touch area container for the slider
        let sliderContainer = UIView()
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sliderContainer)
        
        // Progress slider
        progressSlider = UISlider()
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressSlider.thumbTintColor = .white
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchBegan), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderTouchEnded), for: [.touchUpInside, .touchUpOutside])
        sliderContainer.addSubview(progressSlider)
        
        // Time label
        timeLabel = UILabel()
        timeLabel.textColor = .white
        timeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timeLabel.text = " 0:00 / 0:00 "
        timeLabel.textAlignment = .center
        timeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        timeLabel.layer.cornerRadius = 4
        timeLabel.clipsToBounds = true
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)
        
        NSLayoutConstraint.activate([
            // Slider container fills most of the view
            sliderContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sliderContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            sliderContainer.topAnchor.constraint(equalTo: topAnchor),
            sliderContainer.heightAnchor.constraint(equalToConstant: 44), // Larger touch area
            
            // Actual slider centered in container
            progressSlider.leadingAnchor.constraint(equalTo: sliderContainer.leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: sliderContainer.trailingAnchor, constant: -16),
            progressSlider.centerYAnchor.constraint(equalTo: sliderContainer.centerYAnchor),
            
            timeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timeLabel.topAnchor.constraint(equalTo: sliderContainer.bottomAnchor, constant: 4),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            timeLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
    }
    
    @objc private func sliderTouchBegan() {
        isScrubbing = true
        player.pause()
    }
    
    @objc private func sliderTouchEnded() {
        isScrubbing = false
        player.play()
    }
    
    @objc private func sliderValueChanged(_ slider: UISlider) {
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            let time = duration * Double(slider.value)
            player.seek(to: CMTime(seconds: time, preferredTimescale: 1))
            timeLabel.text = " \(formatTime(time)) / \(formatTime(duration)) "
        }
    }
    
    @objc func leftDoubleTapped() {
        let currentTime = player.currentTime()
        let newTime = CMTimeSubtract(currentTime, CMTime(seconds: skipDuration, preferredTimescale: 1))
        player.seek(to: newTime)
        
        // Show skip indicator
        showSkipIndicator(forward: false)
    }
    
    @objc func rightDoubleTapped() {
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipDuration, preferredTimescale: 1))
        player.seek(to: newTime)
        
        // Show skip indicator
        showSkipIndicator(forward: true)
    }
    
    private func showSkipIndicator(forward: Bool) {
        guard let superview = superview else { return }
        
        let label = UILabel()
        label.text = forward ? " +\(Int(skipDuration))s " : " -\(Int(skipDuration))s "
        label.textColor = .white
        label.font = .systemFont(ofSize: 32, weight: .heavy)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.textAlignment = .center
        label.layer.borderWidth = 2
        label.layer.borderColor = UIColor.white.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        
        superview.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: superview.centerXAnchor, constant: forward ? 100 : -100),
            label.centerYAnchor.constraint(equalTo: superview.centerYAnchor, constant: -50),
            label.widthAnchor.constraint(equalToConstant: 120),
            label.heightAnchor.constraint(equalToConstant: 60)
        ])
        
        UIView.animate(withDuration: 0.3, delay: 0.5, options: .curveEaseOut) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
    
    private func startTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 10)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isScrubbing else { return }
            
            let currentSeconds = time.seconds
            let duration = self.player.currentItem?.duration.seconds ?? 0
            
            if duration.isFinite && duration > 0 {
                self.progressSlider.value = Float(currentSeconds / duration)
                self.timeLabel.text = " \(self.formatTime(currentSeconds)) / \(self.formatTime(duration)) "
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
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
                                CachedAsyncImage(
                                    url: user.avatar != nil ? URL(string: "\(NetworkManager.shared.baseURL)\(user.avatar!)") : nil,
                                    placeholder: {
                                        AnyView(
                                            Image(systemName: "person.circle.fill")
                                                .font(.system(size: 80))
                                                .foregroundColor(.gray)
                                        )
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
                .environmentObject(FavoritesManager.shared)
                .environmentObject(DeletionManager.shared)
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
    @EnvironmentObject var deletionManager: DeletionManager
    @State private var currentIndex: Int
    @State private var players: [Int: AVPlayer] = [:]
    @State private var aspectModes: [Int: ContentMode] = [:] // Track aspect modes per image
    @State private var isLandscape = false
    @AppStorage("skipDuration") private var skipDuration: Double = 5.0

    init(items: [MediaItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Main swipeable media view
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ZStack {
                        if item.isVideo {
                            GeometryReader { geometry in
                                EnhancedVideoPlayerView(
                                    url: URL(string: item.fullURL)!,
                                    player: bindingForPlayer(at: index),
                                    skipDuration: skipDuration,
                                    isLandscape: $isLandscape
                                )
                                .frame(
                                    width: isLandscape ? geometry.size.height : geometry.size.width,
                                    height: isLandscape ? geometry.size.width : geometry.size.height
                                )
                                .rotationEffect(.degrees(isLandscape ? 90 : 0))
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                                .animation(.easeInOut(duration: 0.3), value: isLandscape)
                                .onAppear { players[index]?.play() }
                                .onDisappear { players[index]?.pause() }
                            }
                        } else {
                            // FIX: Use the new ZoomableImageView with a binding to the gallery's state
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

            // Top controls - hide in landscape
            if !isLandscape {
                VStack {
                    HStack {
                        Button("Done") {
                            dismiss()
                        }
                        .foregroundColor(.white)
                        .padding()

                        Spacer()

                        if currentIndex < items.count {
                            HStack(spacing: 20) {
                                // Rotate button for videos
                                if items[currentIndex].isVideo {
                                    Button(action: {
                                        withAnimation {
                                            isLandscape.toggle()
                                        }
                                    }) {
                                        Image(systemName: isLandscape ? "rotate.left" : "rotate.right")
                                            .font(.system(size: 24))
                                            .foregroundColor(.white)
                                    }
                                }
                                
                                // Trash
                                Button(action: {
                                    Task {
                                        await deletionManager.toggleDeletion(items[currentIndex])
                                    }
                                }) {
                                    Image(systemName: deletionManager.isMarkedForDeletion(items[currentIndex]) ? "trash.fill" : "trash")
                                        .font(.system(size: 24))
                                        .foregroundColor(deletionManager.isMarkedForDeletion(items[currentIndex]) ? .red : .white)
                                }

                                // Like
                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                        favoritesManager.toggleFavorite(items[currentIndex])
                                    }
                                }) {
                                    Image(systemName: favoritesManager.isFavorite(items[currentIndex]) ? "heart.fill" : "heart")
                                        .font(.system(size: 24))
                                        .foregroundColor(favoritesManager.isFavorite(items[currentIndex]) ? .red : .white)
                                }
                            }
                            .padding()
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

            // Floating toggle button for images (bottom left) - hide in landscape
            if currentIndex < items.count && !items[currentIndex].isVideo && !isLandscape {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                let currentMode = aspectModes[currentIndex, default: .fit]
                                aspectModes[currentIndex] = (currentMode == .fit) ? .fill : .fit
                            }
                        }) {
                            let currentMode = aspectModes[currentIndex, default: .fit]
                            Image(systemName: currentMode == .fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .padding(.leading, 20)
                        .padding(.bottom, 60) // Safe for bottom nav
                        Spacer()
                    }
                }
            }
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            players[oldValue]?.pause()
            players[newValue]?.play()
            isLandscape = false // Reset rotation when changing items
        }
    }

    private func bindingForPlayer(at index: Int) -> Binding<AVPlayer?> {
        Binding(
            get: { players[index] },
            set: { players[index] = $0 }
        )
    }

    private func bindingForAspectMode(at index: Int) -> Binding<ContentMode> {
        Binding<ContentMode>(
            get: { aspectModes[index, default: .fit] },
            set: { aspectModes[index] = $0 }
        )
    }
}


// MARK: - Settings View (with skip duration)
struct SettingsView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @State private var serverURL: String = ""
    @State private var showingAlert = false
    @AppStorage("skipDuration") private var skipDuration: Double = 5.0
    
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
                
                Section("Video Controls") {
                    HStack {
                        Text("Skip Duration")
                        Spacer()
                        Picker("Skip Duration", selection: $skipDuration) {
                            Text("5 seconds").tag(5.0)
                            Text("10 seconds").tag(10.0)
                            Text("15 seconds").tag(15.0)
                            Text("30 seconds").tag(30.0)
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                }
                
                Section("Cache") {
                    Button("Clear Image Cache") {
                        URLCache.shared.removeAllCachedResponses()
                        ImageCache.shared.clearCache()
                    }
                    
                    Button("Clear All Caches") {
                        URLCache.shared.removeAllCachedResponses()
                        ImageCache.shared.clearCache()
                        // Clear user defaults cache
                        if let bundleID = Bundle.main.bundleIdentifier {
                            UserDefaults.standard.removePersistentDomain(forName: bundleID)
                        }
                    }
                    .foregroundColor(.red)
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.1.0")
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
