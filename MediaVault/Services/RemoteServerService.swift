import Foundation

// MARK: - API response DTOs

private struct ProfilesResponse: Decodable {
    let profiles: [RemoteProfileDTO]
}

private struct RemoteProfileDTO: Decodable {
    let id: String          // folder name used in URL paths, e.g. "alice"
    let name: String        // display name
    let imageCount: Int
    let videoCount: Int
    let subfolders: [String]
    let thumbnailPath: String?  // relative path, e.g. "alice/cover.jpg"
}

private struct ItemsResponse: Decodable {
    let items: [RemoteItemDTO]
}

private struct RemoteItemDTO: Decodable {
    let fileName: String
    let mediaType: String   // "image" or "video"
    let subfolder: String?
    let path: String        // relative path from root, e.g. "alice/photo.jpg"
}

// MARK: - Service

@Observable
final class RemoteServerService {

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "remoteEnabled") }
    }
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "remoteServerURL") }
    }
    var isAuthenticated = false

    /// Normalized base URL, e.g. "https://vault.example.com"
    var baseURL: URL? {
        guard isEnabled, !serverURL.isEmpty else { return nil }
        var str = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.hasPrefix("http://") && !str.hasPrefix("https://") {
            str = "https://" + str
        }
        if str.hasSuffix("/") { str = String(str.dropLast()) }
        return URL(string: str)
    }

    /// Root URL to pass as `rootURL` throughout the app for likes resolution.
    /// Points to /api/files so that relative paths like "alice/photo.jpg" resolve correctly.
    var filesBaseURL: URL? {
        baseURL?.appendingPathComponent("api/files")
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "remoteEnabled")
        self.serverURL = UserDefaults.standard.string(forKey: "remoteServerURL") ?? ""
    }

    /// Quick auth check — hits /api/auth/check which returns 200 when the session cookie is valid.
    func checkAuth() async {
        guard let base = baseURL else { isAuthenticated = false; return }
        do {
            let (_, response) = try await URLSession.shared.data(from: base.appendingPathComponent("api/auth/check"))
            isAuthenticated = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            isAuthenticated = false
        }
    }

    /// Fetches all profiles and their media items from the server.
    /// Runs item fetches concurrently across profiles for speed.
    func fetchProfiles() async throws -> [MediaProfile] {
        guard let base = baseURL else { throw RemoteError.notConfigured }

        let profilesURL = base.appendingPathComponent("api/profiles")
        let (data, response) = try await URLSession.shared.data(from: profilesURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RemoteError.unauthorized
        }
        let profileList = try JSONDecoder().decode(ProfilesResponse.self, from: data)

        var profiles: [MediaProfile] = []
        try await withThrowingTaskGroup(of: MediaProfile?.self) { group in
            for dto in profileList.profiles {
                group.addTask { [weak self] in
                    try await self?.buildProfile(dto: dto, baseURL: base)
                }
            }
            for try await profile in group {
                if let profile { profiles.append(profile) }
            }
        }

        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return profiles
    }

    private func buildProfile(dto: RemoteProfileDTO, baseURL: URL) async throws -> MediaProfile {
        let profileID = UUID()
        let itemsURL = baseURL.appendingPathComponent("api/profiles/\(dto.id)/items")
        let (itemsData, _) = try await URLSession.shared.data(from: itemsURL)
        let itemsResponse = try JSONDecoder().decode(ItemsResponse.self, from: itemsData)
        let filesBase = baseURL.appendingPathComponent("api/files")

        let mediaItems: [MediaItem] = itemsResponse.items.compactMap { item in
            guard let type = MediaItemType(rawValue: item.mediaType) else { return nil }
            let fileURL = filesBase.appendingPathComponent(item.path)
            return MediaItem(
                id: UUID(), url: fileURL, fileName: item.fileName,
                mediaType: type, profileID: profileID, profileName: dto.name,
                subfolder: item.subfolder
            )
        }

        let thumbnailURL = dto.thumbnailPath.flatMap {
            baseURL.appendingPathComponent("api/thumbnails/\($0)")
        }

        return MediaProfile(
            id: profileID, name: dto.name,
            folderURL: baseURL.appendingPathComponent("api/files/\(dto.id)"),
            thumbnailURL: thumbnailURL, mediaItems: mediaItems, subfolders: dto.subfolders
        )
    }

    /// Moves a media file on the server to its Trash folder.
    /// Calls DELETE /api/media/{path}
    func deleteItem(path: String) async throws {
        guard let base = baseURL else { throw RemoteError.notConfigured }
        let url = base.appendingPathComponent("api/media").appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RemoteError.deleteFailed
        }
    }

    enum RemoteError: LocalizedError {
        case notConfigured
        case unauthorized
        case deleteFailed
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Server URL is not configured."
            case .unauthorized:  return "Not authenticated. Please sign in first."
            case .deleteFailed:  return "The server could not move the file to Trash."
            }
        }
    }
}
