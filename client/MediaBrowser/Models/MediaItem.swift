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
    let modified: Date?

    var id: String { uniqueID }

    var fullURL: String {
        resolvedURL?.absoluteString ?? url
    }

    var thumbnailURL: String? {
        guard let thumbnail else { return nil }

        if let direct = URL(string: thumbnail), direct.scheme != nil {
            return direct.absoluteString
        }

        guard let base = URL(string: NetworkManager.shared.baseURL) else { return nil }
        if thumbnail.hasPrefix("/") {
            return URL(string: thumbnail, relativeTo: base)?.absoluteString
        }
        return base.appendingPathComponent(thumbnail).absoluteString
    }

    var isVideo: Bool {
        ["mp4", "mov", "m4v", "avi", "webm"].contains(type)
    }

    var isLocal: Bool {
        if let resolved = URL(string: url), let scheme = resolved.scheme, !scheme.isEmpty {
            return scheme == "file"
        }
        return false
    }

    var uniqueID: String {
        if let fullPath, !fullPath.isEmpty {
            return fullPath
        }
        return "\(username ?? "unknown")_\(path)"
    }

    var resolvedURL: URL? {
        if let direct = URL(string: url), let scheme = direct.scheme, !scheme.isEmpty {
            return direct
        }

        guard let base = URL(string: NetworkManager.shared.baseURL) else {
            return nil
        }

        if url.hasPrefix("/") {
            return URL(string: url, relativeTo: base)?.absoluteURL
        }

        return base.appendingPathComponent(url)
    }

    var feedUserKey: String {
        if let username = username, !username.isEmpty {
            return username
        }

        if !path.isEmpty, let first = path.split(separator: "/").first {
            return String(first)
        }

        if let fullPath = fullPath, let first = fullPath.split(separator: "/").first {
            return String(first)
        }

        return uniqueID
    }
}
