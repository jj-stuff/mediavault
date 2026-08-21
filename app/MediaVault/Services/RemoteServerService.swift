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

    /// Folder on the server — relative to *its* media root — that this app treats
    /// as the library. Empty means the server's media root, which is what every
    /// install had before this setting existed.
    ///
    /// It only changes which folders are read as profiles. Item paths, and so
    /// likes and deletes, stay relative to the server's media root either way, so
    /// switching between `peeps` and `peeps2` does not orphan anything.
    var libraryRootPath: String {
        didSet { store.write(libraryRootPath, forKey: StorageKey.remoteLibraryRoot) }
    }

    private(set) var isAuthenticated = false

    private let store: KeyValueStore
    private let urlSession: URLSession

    init(store: KeyValueStore, urlSession: URLSession = .shared) {
        self.store = store
        self.urlSession = urlSession
        self.isEnabled = store.bool(forKey: StorageKey.remoteEnabled)
        self.serverURL = store.string(forKey: StorageKey.remoteServerURL) ?? ""
        self.libraryRootPath = store.string(forKey: StorageKey.remoteLibraryRoot) ?? ""
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

    /// A library endpoint with the chosen root attached.
    ///
    /// The parameter is left off entirely when the root is the server's own media
    /// root, so the requests an unconfigured app makes are byte-for-byte what they
    /// were before, and an older server that ignores `root=` still answers them.
    private func libraryURL(_ path: String, base: URL) -> URL {
        let url = base.appending(path: path)
        guard !libraryRootPath.isEmpty else { return url }
        return url.appending(queryItems: [URLQueryItem(name: "root", value: libraryRootPath)])
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

        let listing: ProfilesResponse = try await get(libraryURL("api/profiles", base: base))

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
        let itemsURL = libraryURL("api/profiles/\(dto.id)/items", base: baseURL)
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
                subfolder: item.subfolder,
                byteSize: item.byteSize,
                // Seconds since the epoch on the wire: a JSON date format is one more
                // thing for the two sides to disagree about.
                modifiedAt: item.modifiedAt.map(Date.init(timeIntervalSince1970:))
            )
        }

        return MediaProfile(
            id: profileID,
            name: dto.name,
            // `path` rather than `id`: under a chosen library root a profile is
            // `peeps/alice`, and only its last component is the id. Optional so a
            // server older than the root setting still resolves to something.
            folderURL: filesBase.appending(path: dto.path ?? dto.id),
            thumbnailURL: dto.thumbnailPath.map { baseURL.appending(path: "api/thumbnails/\($0)") },
            mediaItems: mediaItems,
            subfolders: dto.subfolders
        )
    }

    // MARK: - Folder browsing

    /// Lists the folders directly inside `path` on the server.
    ///
    /// Used by the library-root picker, and only there: browsing the tree is a
    /// setup question, not something the library screens ever need.
    func fetchFolders(at path: String) async throws -> RemoteFolderListing {
        guard let base = baseURL else { throw RemoteError.notConfigured }

        var url = base.appending(path: "api/folders")
        if !path.isEmpty {
            url = url.appending(queryItems: [URLQueryItem(name: "path", value: path)])
        }

        let response: FoldersResponse = try await get(url)
        return RemoteFolderListing(
            path: response.path,
            parent: response.parent,
            folders: response.folders
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
    let id: String              // folder name used to ask for this profile's items
    let name: String            // display name
    let imageCount: Int
    let videoCount: Int
    let subfolders: [String]
    let thumbnailPath: String?  // relative path, e.g. "alice/cover.jpg"
    // Path relative to the server's media root, e.g. "peeps/alice". Optional so the
    // app keeps working against a server that predates the library-root setting.
    let path: String?
}

private struct FoldersResponse: Decodable {
    let path: String
    let parent: String?
    let folders: [RemoteFolder]
}

private struct ItemsResponse: Decodable {
    let items: [RemoteItemDTO]
}

private struct RemoteItemDTO: Decodable {
    let fileName: String
    let mediaType: String       // "image" or "video"
    let subfolder: String?
    let path: String            // relative to the library root
    let byteSize: Int64?        // size on disk
    let modifiedAt: Double?     // seconds since the epoch
}

// MARK: - Folder listings

/// One folder on the server, offered as a candidate library root.
nonisolated struct RemoteFolder: Identifiable, Hashable, Sendable, Decodable {
    let name: String
    /// Relative to the server's media root, e.g. `peeps/alice`.
    let path: String
    /// Immediate subfolders, and media files directly inside. Between them the
    /// picker can say whether a folder holds profiles or holds the photos itself.
    let folderCount: Int
    let itemCount: Int

    var id: String { path }
}

nonisolated struct RemoteFolderListing: Sendable {
    /// The folder that was listed. Empty at the server's media root.
    let path: String
    /// Parent of `path`, or `nil` at the top — supplied by the server so the picker
    /// does not do path arithmetic of its own.
    let parent: String?
    let folders: [RemoteFolder]
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
