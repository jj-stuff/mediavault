import Foundation

// MARK: - MediaItemType

nonisolated enum MediaItemType: String, Codable, CaseIterable, Sendable {
    case image
    case video
}

// MARK: - MediaItem

nonisolated struct MediaItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let fileName: String
    let mediaType: MediaItemType
    let profileID: UUID
    let profileName: String
    let subfolder: String?

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv"
    ]

    static let allSupportedExtensions: Set<String> = imageExtensions.union(videoExtensions)

    static func mediaType(for ext: String) -> MediaItemType? {
        let lowered = ext.lowercased()
        if imageExtensions.contains(lowered) { return .image }
        if videoExtensions.contains(lowered) { return .video }
        return nil
    }
}

// MARK: - MediaProfile

nonisolated struct MediaProfile: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let folderURL: URL
    var thumbnailURL: URL?
    var mediaItems: [MediaItem]
    var subfolders: [String]

    var imageCount: Int { mediaItems.filter { $0.mediaType == .image }.count }
    var videoCount: Int { mediaItems.filter { $0.mediaType == .video }.count }
    var totalCount: Int { mediaItems.count }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MediaProfile, rhs: MediaProfile) -> Bool { lhs.id == rhs.id }
}

// MARK: - LikedItem

nonisolated struct LikedItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let relativePath: String
    let profileName: String
    let mediaType: MediaItemType
    let likedAt: Date

    init(from mediaItem: MediaItem, rootURL: URL) {
        self.id = UUID()
        let fullPath = mediaItem.url.path
        let rootPath = rootURL.path
        var raw = fullPath.hasPrefix(rootPath)
            ? String(fullPath.dropFirst(rootPath.count))
            : mediaItem.url.lastPathComponent
        if raw.hasPrefix("/") { raw = String(raw.dropFirst()) }
        self.relativePath = raw
        self.profileName = mediaItem.profileName
        self.mediaType = mediaItem.mediaType
        self.likedAt = Date()
    }

    func resolvedURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(relativePath)
    }

    func toMediaItem(rootURL: URL, profileID: UUID) -> MediaItem {
        let url = resolvedURL(rootURL: rootURL)
        return MediaItem(
            id: id, url: url, fileName: url.lastPathComponent,
            mediaType: mediaType, profileID: profileID,
            profileName: profileName, subfolder: nil
        )
    }
}
