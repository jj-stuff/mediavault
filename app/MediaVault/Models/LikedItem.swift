import Foundation

/// A favourite, stored as a path relative to the library root.
///
/// Storing a relative path rather than an absolute URL is what lets likes survive
/// the root moving — a re-picked folder, a different external drive, or the same
/// library reached through the server instead of the filesystem.
nonisolated struct LikedItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let relativePath: String
    let profileName: String
    let mediaType: MediaItemType
    let likedAt: Date

    init(from mediaItem: MediaItem, rootURL: URL) {
        self.id = UUID()
        self.relativePath = MediaPath.relative(for: mediaItem.url, under: rootURL)
        self.profileName = mediaItem.profileName
        self.mediaType = mediaItem.mediaType
        self.likedAt = Date()
    }

    func resolvedURL(rootURL: URL) -> URL {
        rootURL.appending(path: relativePath)
    }

    func toMediaItem(rootURL: URL, profileID: UUID) -> MediaItem {
        let url = resolvedURL(rootURL: rootURL)
        return MediaItem(
            id: id,
            url: url,
            fileName: url.lastPathComponent,
            mediaType: mediaType,
            profileID: profileID,
            profileName: profileName,
            subfolder: nil
        )
    }
}
