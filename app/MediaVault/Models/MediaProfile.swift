import Foundation

nonisolated struct MediaProfile: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let folderURL: URL
    var thumbnailURL: URL?
    var mediaItems: [MediaItem]
    var subfolders: [String]

    var imageCount: Int { mediaItems.count { $0.mediaType == .image } }
    var videoCount: Int { mediaItems.count { $0.mediaType == .video } }
    var totalCount: Int { mediaItems.count }

    /// Aggregates used to sort the profile list itself.
    var totalByteSize: Int64 {
        mediaItems.reduce(0) { $0 + ($1.byteSize ?? 0) }
    }

    var lastModified: Date? {
        mediaItems.compactMap(\.modifiedAt).max()
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MediaProfile, rhs: MediaProfile) -> Bool { lhs.id == rhs.id }

    /// The profile's cover, shaped as a `MediaItem` so it can go through the same
    /// thumbnail path as everything else instead of needing a second loader.
    var coverItem: MediaItem? {
        guard let thumbnailURL else { return nil }
        return MediaItem(
            id: id,
            url: thumbnailURL,
            fileName: thumbnailURL.lastPathComponent,
            mediaType: MediaItem.mediaType(for: thumbnailURL.pathExtension) ?? .image,
            profileID: id,
            profileName: name,
            subfolder: nil
        )
    }
}
