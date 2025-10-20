import Foundation

struct MediaItem: Identifiable, Codable, Hashable {
    let name: String
    let path: String
    let url: String
    let fullPath: String?
    let size: Int
    let type: String
    let username: String?
    let thumbnail: String?

    var id: String { uniqueID }

    var fullURL: String {
        "\(NetworkManager.shared.baseURL)\(url)"
    }

    var thumbnailURL: String? {
        guard let thumbnail else { return nil }
        return "\(NetworkManager.shared.baseURL)\(thumbnail)"
    }

    var isVideo: Bool {
        ["mp4", "mov", "avi", "webm"].contains(type)
    }

    var uniqueID: String {
        "\(username ?? "unknown")_\(path)"
    }
}
