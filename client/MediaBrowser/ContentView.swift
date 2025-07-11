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
                .preferredColorScheme(.dark) // Better for media viewing
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

struct MediaItem: Identifiable, Codable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let url: String
    let fullPath: String? // Server now provides full system path
    let size: Int
    let type: String
    let username: String?
    let thumbnail: String?
    
    var fullURL: String {
        return "\(NetworkManager.shared.baseURL)\(url)"
    }
    
    var thumbnailURL: String? {
        guard let thumbnail = thumbnail else { return nil }
        return "\(NetworkManager.shared.baseURL)\(thumbnail)"
    }
    
    var isVideo: Bool {
        ["mp4", "mov", "avi", "webm"].contains(type)
    }
    
    var uniqueID: String {
        return "\(username ?? "unknown")_\(path)"
    }
    
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        return lhs.uniqueID == rhs.uniqueID
    }
    
    enum CodingKeys: String, CodingKey {
        case name, path, url, fullPath, size, type, username, thumbnail
    }
}

// MARK: - Server Settings
struct ServerSettings: Codable {
    var scheme: String = "http"
    var host: String = "192.168.1.123"
    var port: String = "3000"
    
    var fullURL: String {
        return "\(scheme)://\(host):\(port)"
    }
    
    static let storageKey = "ServerSettings"
    
    static func load() -> ServerSettings {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let settings = try? JSONDecoder().decode(ServerSettings.self, from: data) {
            return settings
        }
        return ServerSettings()
    }
    
    func save() {
        if let encoded = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(encoded, forKey: ServerSettings.storageKey)
        }
    }
}

// MARK: - Favorites Manager
class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()
    @Published var favoriteIDs: Set<String> = []
    
    private let favoritesKey = "UserFavorites"
    private let queue = DispatchQueue(label: "favorites.queue", attributes: .concurrent)
    
    init() {
        loadFavorites()
    }
    
    func loadFavorites() {
        queue.async(flags: .barrier) { [weak self] in
            if let data = UserDefaults.standard.data(forKey: self?.favoritesKey ?? ""),
               let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
                DispatchQueue.main.async {
                    self?.favoriteIDs = decoded
                }
            }
        }
    }
    
    func saveFavorites() {
        queue.async(flags: .barrier) { [weak self] in
            if let encoded = try? JSONEncoder().encode(self?.favoriteIDs) {
                UserDefaults.standard.set(encoded, forKey: self?.favoritesKey ?? "")
            }
        }
    }
    
    func toggleFavorite(_ item: MediaItem) {
        DispatchQueue.main.async { [weak self] in
            if self?.favoriteIDs.contains(item.uniqueID) == true {
                self?.favoriteIDs.remove(item.uniqueID)
            } else {
                self?.favoriteIDs.insert(item.uniqueID)
            }
            self?.saveFavorites()
        }
    }
    
    func isFavorite(_ item: MediaItem) -> Bool {
        return favoriteIDs.contains(item.uniqueID)
    }
}

// MARK: - Deletion Manager
class DeletionManager: ObservableObject {
    static let shared = DeletionManager()
    @Published var markedForDeletion: Set<String> = []
    @Published var isUpdating = false
    
    private let queue = DispatchQueue(label: "deletion.queue")
    
    func toggleDeletion(_ item: MediaItem) async {
        // Use the full system path provided by server
        let pathToUse = item.fullPath ?? item.url
        
        await MainActor.run {
            self.isUpdating = true
        }
        
        do {
            if markedForDeletion.contains(pathToUse) {
                // Remove from deletion list
                try await removeFromDeletionList(pathToUse)
                await MainActor.run {
                    self.markedForDeletion.remove(pathToUse)
                }
            } else {
                // Add to deletion list
                try await addToDeletionList(pathToUse)
                await MainActor.run {
                    self.markedForDeletion.insert(pathToUse)
                }
            }
        } catch {
            print("Error updating deletion list: \(error)")
        }
        
        await MainActor.run {
            self.isUpdating = false
        }
    }
    
    func isMarkedForDeletion(_ item: MediaItem) -> Bool {
        let pathToCheck = item.fullPath ?? item.url
        return markedForDeletion.contains(pathToCheck)
    }
    
    private func addToDeletionList(_ path: String) async throws {
        let url = URL(string: "\(NetworkManager.shared.baseURL)/api/deletion-list/add")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path])
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
    
    private func removeFromDeletionList(_ path: String) async throws {
        let url = URL(string: "\(NetworkManager.shared.baseURL)/api/deletion-list/remove")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path])
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
    
    func loadDeletionList() async {
        guard let url = URL(string: "\(NetworkManager.shared.baseURL)/api/deletion-list") else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(DeletionListResponse.self, from: data)
            
            await MainActor.run {
                self.markedForDeletion = Set(response.paths)
            }
        } catch {
            print("Error loading deletion list: \(error)")
        }
    }
}

struct DeletionListResponse: Codable {
    let success: Bool
    let paths: [String]
    let count: Int
    let location: String?
}

// MARK: - Network Manager
class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    
    @Published var serverSettings: ServerSettings {
        didSet {
            serverSettings.save()
        }
    }
    
    var baseURL: String {
        return serverSettings.fullURL
    }
    
    @Published var users: [User] = []
    @Published var feedItems: [MediaItem] = []
    @Published var isLoading = false
    
    private var etag: String?
    private let session: URLSession
    
    init() {
        self.serverSettings = ServerSettings.load()
        
        // Configure URLSession with optimized settings
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 10
        
        self.session = URLSession(configuration: configuration)
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
            let (data, _) = try await session.data(from: url)
            let decodedResponse = try JSONDecoder().decode(UsersResponse.self, from: data)
            
            // Fetch user details concurrently
            let userDetails = await withTaskGroup(of: User?.self) { group in
                for username in decodedResponse.users {
                    group.addTask { [weak self] in
                        await self?.fetchUserProfile(username: username)
                    }
                }
                
                var users: [User] = []
                for await user in group {
                    if let user = user {
                        users.append(user)
                    }
                }
                return users.sorted { $0.username < $1.username }
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
            let (data, _) = try await session.data(from: url)
            let profileResponse = try JSONDecoder().decode(UserProfileResponse.self, from: data)
            return profileResponse.user
        } catch {
            print("Error fetching user profile for \(username): \(error)")
            return nil
        }
    }
    
    func fetchUserMedia(username: String) async -> [String: [MediaItem]] {
        guard let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/users/\(encodedUsername)/media") else { return [:] }
        
        var request = URLRequest(url: url)
        if let etag = self.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        
        do {
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 304 {
                    // Not modified, use cached data
                    return [:]
                }
                
                // Store ETag for future requests
                if let newEtag = httpResponse.value(forHTTPHeaderField: "ETag") {
                    self.etag = newEtag
                }
            }
            
            let flatResponse = try JSONDecoder().decode(FlatUserMediaResponse.self, from: data)
            
            // Group by type
            var grouped: [String: [MediaItem]] = [:]
            for item in flatResponse.media {
                if grouped[item.type] == nil {
                    grouped[item.type] = []
                }
                grouped[item.type]?.append(item)
            }
            return grouped
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
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(FeedResponse.self, from: data)
            
            await MainActor.run {
                // Append new items, avoiding duplicates
                let existingIDs = Set(self.feedItems.map { $0.uniqueID })
                let newItems = response.media.filter { !existingIDs.contains($0.uniqueID) }
                self.feedItems.append(contentsOf: newItems)
            }
        } catch {
            print("Error fetching feed: \(error)")
        }
    }
    
    func clearCache() async {
        guard let url = URL(string: "\(baseURL)/api/cache/clear") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        do {
            let (_, _) = try await session.data(for: request)
            self.etag = nil
        } catch {
            print("Error clearing cache: \(error)")
        }
    }
    
    func refreshCache() async {
        guard let url = URL(string: "\(baseURL)/api/cache/refresh") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        do {
            let (_, _) = try await session.data(for: request)
            self.etag = nil
        } catch {
            print("Error refreshing cache: \(error)")
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

struct FlatUserMediaResponse: Codable {
    let success: Bool
    let count: Int
    let media: [MediaItem]
}

struct FeedResponse: Codable {
    let success: Bool
    let media: [MediaItem]
}

// MARK: - Enhanced Image Cache
class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private let diskCache = URLCache(
        memoryCapacity: 50 * 1024 * 1024, // 50MB memory
        diskCapacity: 200 * 1024 * 1024,   // 200MB disk
        diskPath: "ImageCache"
    )
    
    init() {
        cache.countLimit = 200
        cache.totalCostLimit = 100 * 1024 * 1024 // 100MB
    }
    
    func setImage(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.pngData()?.count ?? 0)
    }
    
    func getImage(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }
    
    func clearCache() {
        cache.removeAllObjects()
        diskCache.removeAllCachedResponses()
    }
}

// MARK: - Optimized Image Loading
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
                    .progressViewStyle(CircularProgressViewStyle())
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
        
        // Check memory cache first
        if let cachedImage = ImageCache.shared.getImage(forKey: url.absoluteString) {
            self.image = cachedImage
            return
        }
        
        isLoading = true
        
        Task {
            do {
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
                let (data, _) = try await URLSession.shared.data(for: request)
                
                if let downloadedImage = UIImage(data: data) {
                    // Resize image if too large
                    let resizedImage = downloadedImage.size.width > 1024 || downloadedImage.size.height > 1024
                        ? downloadedImage.resized(toWidth: 1024) ?? downloadedImage
                        : downloadedImage
                    
                    await MainActor.run {
                        self.image = resizedImage
                        self.isLoading = false
                        ImageCache.shared.setImage(resizedImage, forKey: url.absoluteString)
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

// MARK: - Image Resizing Extension
extension UIImage {
    func resized(toWidth width: CGFloat) -> UIImage? {
        let scale = width / self.size.width
        let newHeight = self.size.height * scale
        let size = CGSize(width: width, height: newHeight)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        draw(in: CGRect(origin: .zero, size: size))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage
    }
}

// MARK: - Zoomable Image View
struct ZoomableImageView: View {
    let url: String
    @Binding var aspectMode: ContentMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            AsyncImage(url: URL(string: url)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: aspectMode)
            } placeholder: {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Main Content View
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
        .task {
            await deletionManager.loadDeletionList()
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

// MARK: - Feed View
struct FeedView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject var favoritesManager: FavoritesManager
    @State private var currentIndex = 0
    @State private var mediaFilter: MediaFilter = .all
    @State private var isLoading = false
    @State private var visibleIndex: Int? = nil
    
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
            if networkManager.feedItems.isEmpty && !networkManager.isLoading {
                VStack {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No media available")
                        .foregroundColor(.secondary)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(networkManager.feedItems.enumerated()), id: \.element.id) { index, item in
                            FeedItemView(item: item, isVisible: visibleIndex == index)
                                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                                .onAppear {
                                    // Set visible index immediately for videos to start playing
                                    visibleIndex = index
                                    
                                    // Load more when near end
                                    if index >= networkManager.feedItems.count - 5 && !isLoading {
                                        Task {
                                            isLoading = true
                                            await networkManager.fetchRandomFeed(limit: 30, mediaType: mediaFilter.apiValue)
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
            
            // Filter buttons
            VStack {
                HStack {
                    ForEach(MediaFilter.allCases, id: \.self) { filter in
                        Button(action: {
                            mediaFilter = filter
                            Task {
                                networkManager.feedItems = []
                                await networkManager.fetchRandomFeed(limit: 30, mediaType: filter.apiValue)
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
                .padding(.top, 55)
                
                Spacer()
            }
            
            // Loading indicator
            if networkManager.isLoading && networkManager.feedItems.isEmpty {
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .task {
            if networkManager.feedItems.isEmpty {
                await networkManager.fetchRandomFeed(limit: 30, mediaType: mediaFilter.apiValue)
            }
        }
    }
}

// MARK: - Liked View
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
                .navigationTitle("Liked")
            }
        }
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
        
        if networkManager.users.isEmpty {
            await networkManager.fetchUsers()
        }
        
        await withTaskGroup(of: [MediaItem].self) { group in
            for user in networkManager.users {
                group.addTask {
                    let userMedia = await networkManager.fetchUserMedia(username: user.username)
                    return userMedia.values.flatMap { $0 }.filter { favoritesManager.isFavorite($0) }
                }
            }
            
            for await items in group {
                allItems.append(contentsOf: items)
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
    @State private var isLandscape = false
    @AppStorage("skipDuration") private var skipDuration: Double = 5.0
    @State private var aspectMode: ContentMode = .fit
    @State private var isPlayerReady = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if item.isVideo {
                GeometryReader { geometry in
                    EnhancedVideoPlayerView(
                        url: URL(string: item.fullURL)!,
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
                        if isPlayerReady {
                            if newValue {
                                player?.play()
                            } else {
                                player?.pause()
                            }
                        }
                    }
                }
                .ignoresSafeArea()
            } else {
                ZoomableImageView(url: item.fullURL, aspectMode: $aspectMode)
            }
            
            // Side buttons - hide in landscape
            if !isLandscape {
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
                            
                            // Rotate/Zoom button
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
                                if deletionManager.isUpdating {
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
                            .disabled(deletionManager.isUpdating)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 160)
                    }
                }
            }
            
            // Username at bottom
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
                    .padding(.bottom, 140)
                }
            }
        }
    }
}

// MARK: - Enhanced Video Player View
struct EnhancedVideoPlayerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var player: AVPlayer?
    let skipDuration: Double
    @Binding var isLandscape: Bool
    let shouldPlay: Bool
    let onPlayerReady: (() -> Void)?
    
    init(url: URL, player: Binding<AVPlayer?>, skipDuration: Double, isLandscape: Binding<Bool>, shouldPlay: Bool = false, onPlayerReady: (() -> Void)? = nil) {
        self.url = url
        self._player = player
        self.skipDuration = skipDuration
        self._isLandscape = isLandscape
        self.shouldPlay = shouldPlay
        self.onPlayerReady = onPlayerReady
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = .black
        
        // Create player with optimized settings
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = 1.0
        
        // Preload next item
        player.currentItem?.preferredForwardBufferDuration = 5
        
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
        
        // Add tap gesture for play/pause
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        playerViewController.view.addGestureRecognizer(singleTap)
        
        // Create custom controls
        let controlsView = VideoControlsView(player: player, skipDuration: skipDuration)
        controlsView.isHidden = isLandscape
        container.view.addSubview(controlsView)
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor, constant: -60),
            controlsView.heightAnchor.constraint(equalToConstant: 70)
        ])
        
        context.coordinator.controlsView = controlsView
        context.coordinator.playerViewController = playerViewController
        
        // Add double tap gestures
        let leftDoubleTap = UITapGestureRecognizer(target: controlsView, action: #selector(VideoControlsView.leftDoubleTapped))
        leftDoubleTap.numberOfTapsRequired = 2
        leftDoubleTap.require(toFail: singleTap)
        
        let rightDoubleTap = UITapGestureRecognizer(target: controlsView, action: #selector(VideoControlsView.rightDoubleTapped))
        rightDoubleTap.numberOfTapsRequired = 2
        rightDoubleTap.require(toFail: singleTap)
        
        // Create tap areas
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
        
        // Set player and notify when ready
        DispatchQueue.main.async {
            self.player = player
            self.onPlayerReady?()
            
            // Start playing immediately if shouldPlay is true
            if self.shouldPlay {
                player.play()
            }
        }
        
        return container
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if let playerViewController = context.coordinator.playerViewController {
            playerViewController.videoGravity = isLandscape ? .resizeAspectFill : .resizeAspect
        }
        context.coordinator.controlsView?.isHidden = isLandscape
        
        // Handle play state changes
        if shouldPlay {
            player?.play()
        } else {
            player?.pause()
        }
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
        
        let sliderContainer = UIView()
        sliderContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sliderContainer)
        
        progressSlider = UISlider()
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        progressSlider.thumbTintColor = .white
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(sliderTouchBegan), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(sliderTouchEnded), for: [.touchUpInside, .touchUpOutside])
        sliderContainer.addSubview(progressSlider)
        
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
            sliderContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sliderContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            sliderContainer.topAnchor.constraint(equalTo: topAnchor),
            sliderContainer.heightAnchor.constraint(equalToConstant: 44),
            
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
        showSkipIndicator(forward: false)
    }
    
    @objc func rightDoubleTapped() {
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: skipDuration, preferredTimescale: 1))
        player.seek(to: newTime)
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
                        // Profile Header
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
                        
                        // Tab Selection
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
                
                // Sticky header
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

// MARK: - Media Thumbnail View
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
                    // Try server thumbnail first
                    if let thumbnailURL = item.thumbnailURL {
                        AsyncImage(url: URL(string: thumbnailURL)) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: UIScreen.main.bounds.width / 3 - 4, height: UIScreen.main.bounds.width / 3 - 4)
                                .clipped()
                        } placeholder: {
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
                        }
                    } else {
                        // Fallback to local generation
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
                    }
                } else {
                    // Image thumbnail
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
                
                // Video indicator
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

// MARK: - Media Gallery View
struct MediaGalleryView: View {
    let items: [MediaItem]
    let startIndex: Int
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var favoritesManager: FavoritesManager
    @EnvironmentObject var deletionManager: DeletionManager
    @State private var currentIndex: Int
    @State private var players: [Int: AVPlayer] = [:]
    @State private var aspectModes: [Int: ContentMode] = [:]
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

            // Controls overlay
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
                                
                                Button(action: {
                                    Task {
                                        await deletionManager.toggleDeletion(items[currentIndex])
                                    }
                                }) {
                                    if deletionManager.isUpdating {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(0.7)
                                    } else {
                                        Image(systemName: deletionManager.isMarkedForDeletion(items[currentIndex]) ? "trash.fill" : "trash")
                                            .font(.system(size: 24))
                                            .foregroundColor(deletionManager.isMarkedForDeletion(items[currentIndex]) ? .red : .white)
                                    }
                                }
                                .disabled(deletionManager.isUpdating)

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

                    Text("\(currentIndex + 1) / \(items.count)")
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(20)
                        .padding(.bottom)
                }
            }

            // Zoom toggle for images
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
                        .padding(.bottom, 60)
                        Spacer()
                    }
                }
            }
        }
        .onChange(of: currentIndex) { oldValue, newValue in
            players[oldValue]?.pause()
            players[newValue]?.play()
            isLandscape = false
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

// MARK: - Settings View
struct SettingsView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @State private var serverSettings = ServerSettings.load()
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @AppStorage("skipDuration") private var skipDuration: Double = 5.0
    
    var body: some View {
        NavigationStack {
            List {
                Section("Server Connection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Current Server")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(networkManager.baseURL)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(spacing: 16) {
                        HStack {
                            Text("http://")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            TextField("192.168.1.123", text: $serverSettings.host)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.numbersAndPunctuation)
                        }
                        
                        HStack {
                            Text("Port:")
                                .font(.system(.body))
                                .foregroundColor(.secondary)
                            
                            TextField("3000", text: $serverSettings.port)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .keyboardType(.numberPad)
                                .frame(width: 80)
                            
                            Spacer()
                        }
                        
                        Button(action: updateServer) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Update Connection")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Video Controls") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Skip Duration")
                            Spacer()
                            Text("\(Int(skipDuration)) seconds")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $skipDuration, in: 1...60, step: 1)
                            .accentColor(.blue)
                    }
                }
                
                Section("Cache Management") {
                    Button(action: clearImageCache) {
                        HStack {
                            Image(systemName: "photo")
                            Text("Clear Image Cache")
                        }
                    }
                    
                    Button(action: clearServerCache) {
                        HStack {
                            Image(systemName: "server.rack")
                            Text("Clear Server Cache")
                        }
                    }
                    
                    Button(action: refreshServerCache) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Server Cache")
                        }
                    }
                    
                    Button(action: clearAllData) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear All Data")
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("2.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Cache Size")
                        Spacer()
                        Text(formatBytes(URLCache.shared.currentDiskUsage))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Notice", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private func updateServer() {
        networkManager.serverSettings = serverSettings
        alertMessage = "Server updated to \(serverSettings.fullURL)"
        showingAlert = true
        
        Task {
            await networkManager.fetchUsers()
        }
    }
    
    private func clearImageCache() {
        URLCache.shared.removeAllCachedResponses()
        ImageCache.shared.clearCache()
        alertMessage = "Image cache cleared"
        showingAlert = true
    }
    
    private func clearServerCache() {
        Task {
            await networkManager.clearCache()
            alertMessage = "Server cache cleared"
            showingAlert = true
        }
    }
    
    private func refreshServerCache() {
        Task {
            await networkManager.refreshCache()
            await networkManager.fetchUsers()
            alertMessage = "Server cache refreshed"
            showingAlert = true
        }
    }
    
    private func clearAllData() {
        URLCache.shared.removeAllCachedResponses()
        ImageCache.shared.clearCache()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        alertMessage = "All data cleared"
        showingAlert = true
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
