import Foundation

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

    /// True when this item lives on a remote server rather than the local filesystem.
    var isRemote: Bool {
        !url.isFileURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Supported formats

// `nonisolated` has to be repeated here: an extension does not inherit the type's
// isolation, so under the target's MainActor default these would become
// main-actor-only and unusable from the background scan.
nonisolated extension MediaItem {
    /// Kept in sync with IMAGE_EXTENSIONS in server/app/config.py.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif"
    ]

    /// Kept in sync with VIDEO_EXTENSIONS in server/app/config.py.
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
