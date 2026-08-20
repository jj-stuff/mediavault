import Foundation

/// Client for the MediaVault server in `server/`.
///
/// Authentication is a session cookie: the user signs in through a web page in a
/// `WKWebView`, and those cookies are copied into `HTTPCookieStorage.shared` so both
/// these requests and AVPlayer's own range requests are authenticated without any
/// per-request header work.
@Observable
final class RemoteServerService {

    var isEnabled: Bool {
        didSet { store.write(isEnabled, forKey: StorageKey.remoteEnabled) }
    }

    var serverURL: String {
        didSet { store.write(serverURL, forKey: StorageKey.remoteServerURL) }
    }

    private(set) var isAuthenticated = false

    private let store: KeyValueStore
    private let urlSession: URLSession

    init(store: KeyValueStore, urlSession: URLSession = .shared) {
        self.store = store
        self.urlSession = urlSession
        self.isEnabled = store.bool(forKey: StorageKey.remoteEnabled)
        self.serverURL = store.string(forKey: StorageKey.remoteServerURL) ?? ""
    }

    // MARK: - URLs

    /// Normalised base URL, e.g. `https://vault.example.com` or `http://192.168.1.4:8000`.
    ///
    /// When the address has no scheme, one is inferred: `http` for a LAN address,
    /// `https` for anything else. Always assuming `https` meant that typing a NAS's
    /// IP produced a TLS handshake against a plain-HTTP port, which fails in a way
    /// that looks like the server is down.
    var baseURL: URL? {
        guard isEnabled else { return nil }
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = (Self.isLocalAddress(trimmed) ? "http://" : "https://") + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }

    /// True for addresses on the local network, where plain HTTP is both expected
    /// and permitted by the app's `NSAllowsLocalNetworking` exception.
    nonisolated static func isLocalAddress(_ address: String) -> Bool {
        // Strip any path and port to get at the bare host.
        let host = address
            .split(separator: "/", maxSplits: 1).first
            .map(String.init)?
            .split(separator: ":").first
            .map(String.init) ?? address

        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".local") { return true }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        // RFC 1918 private ranges, loopback, and link-local.
        return switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168): true
        case (172, 16...31): true
        case (169, 254): true
        default: false
        }
    }

    /// Root used for relative-path resolution throughout the app in remote mode.
    /// Points at `/api/files` so `alice/photo.jpg` resolves the same way it does
    /// against a local folder root.
    var filesBaseURL: URL? {
        baseURL?.appending(path: "api/files")
    }

    // MARK: - Auth

    func checkAuth() async {
        guard let base = baseURL else {
            isAuthenticated = false
            return
        }
        do {
            let (_, response) = try await urlSession.data(
                from: base.appending(path: "api/auth/check")
            )
            isAuthenticated = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            isAuthenticated = false
        }
    }

    /// Result of the last connection test, for display in Settings.
    private(set) var diagnosis: String?

    /// Probes the server and reports exactly what happened.
    ///
    /// Exists because "it doesn't work" spans two completely different problems
    /// that the sign-in sheet cannot tell apart: never reaching the server at all
    /// (network, port, firewall, ATS) versus reaching it and not being signed in.
    /// A 401 here is a *success* — it proves the connection works end to end.
    func testConnection() async {
        guard let base = baseURL else {
            diagnosis = "No server address set."
            return
        }

        diagnosis = "Testing \(base.absoluteString)…"

        var request = URLRequest(url: base.appending(path: "api/auth/check"))
        request.timeoutInterval = 10
        // Ignore any cached response, or a previous result masks the current state.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await urlSession.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            diagnosis = switch code {
            case 200:
                "Connected and signed in. Everything works."
            case 401, 403:
                "Reached the server — the network side is fine. Tap Sign In to authenticate."
            case 404:
                "Reached something at that address, but it isn't a MediaVault server."
            default:
                "Reached the server, but it replied \(code)."
            }
            isAuthenticated = code == 200
        } catch {
            diagnosis = "Couldn't reach \(base.absoluteString)\n\n\(NetworkErrorMessage.explain(error, url: base))"
            isAuthenticated = false
        }
    }

    // MARK: - Library

    /// Fetches every profile and its items, one request per profile in parallel.
    func fetchProfiles() async throws -> [MediaProfile] {
        guard let base = baseURL else { throw RemoteError.notConfigured }

        let listing: ProfilesResponse = try await get(base.appending(path: "api/profiles"))

        var profiles: [MediaProfile] = []
        profiles.reserveCapacity(listing.profiles.count)

        try await withThrowingTaskGroup(of: MediaProfile.self) { group in
            for dto in listing.profiles {
                group.addTask { try await self.buildProfile(dto: dto, baseURL: base) }
            }
            for try await profile in group {
                profiles.append(profile)
            }
        }

        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return profiles
    }

    private func buildProfile(dto: RemoteProfileDTO, baseURL: URL) async throws -> MediaProfile {
        let profileID = UUID()
        let itemsURL = baseURL.appending(path: "api/profiles/\(dto.id)/items")
        let response: ItemsResponse = try await get(itemsURL)
        let filesBase = baseURL.appending(path: "api/files")

        let mediaItems = response.items.compactMap { item -> MediaItem? in
            guard let type = MediaItemType(rawValue: item.mediaType) else { return nil }
            return MediaItem(
                id: UUID(),
                url: filesBase.appending(path: item.path),
                fileName: item.fileName,
                mediaType: type,
                profileID: profileID,
                profileName: dto.name,
                subfolder: item.subfolder
            )
        }

        return MediaProfile(
            id: profileID,
            name: dto.name,
            folderURL: filesBase.appending(path: dto.id),
            thumbnailURL: dto.thumbnailPath.map { baseURL.appending(path: "api/thumbnails/\($0)") },
            mediaItems: mediaItems,
            subfolders: dto.subfolders
        )
    }

    // MARK: - Mutations

    /// Moves a file into the server's Trash folder. `path` is relative to the
    /// library root, e.g. `alice/photo.jpg`.
    func deleteItem(path: String) async throws {
        guard let base = baseURL else { throw RemoteError.notConfigured }

        var request = URLRequest(url: base.appending(path: "api/media").appending(path: path))
        request.httpMethod = "DELETE"

        let (_, response) = try await urlSession.data(for: request)
        try Self.validate(response)
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await urlSession.data(from: url)
        try Self.validate(response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteError.badResponse
        }
    }

    nonisolated private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteError.badResponse }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw RemoteError.unauthorized
        case 404: throw RemoteError.notFound
        default: throw RemoteError.serverError(http.statusCode)
        }
    }
}

// MARK: - API DTOs

/// These mirror the response models in `server/app/main.py`. Changing one without
/// the other breaks remote mode.
private struct ProfilesResponse: Decodable {
    let profiles: [RemoteProfileDTO]
}

private struct RemoteProfileDTO: Decodable {
    let id: String              // folder name used in URL paths, e.g. "alice"
    let name: String            // display name
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
    let mediaType: String       // "image" or "video"
    let subfolder: String?
    let path: String            // relative to the library root
}

// MARK: - Errors

extension RemoteServerService {
    enum RemoteError: LocalizedError {
        case notConfigured
        case unauthorized
        case notFound
        case badResponse
        case serverError(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Server URL is not configured."
            case .unauthorized:
                "Not signed in. Open Settings and sign in to the server."
            case .notFound:
                "The server could not find that item."
            case .badResponse:
                "The server sent a response the app could not read."
            case .serverError(let code):
                "The server returned an error (\(code))."
            }
        }
    }
}
