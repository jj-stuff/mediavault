import Foundation
import Combine

final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    @Published var serverSettings: ServerSettings {
        didSet {
            let normalized = serverSettings.normalized()
            if normalized != serverSettings {
                serverSettings = normalized
                return
            }
            serverSettings.save()
        }
    }

    @Published private(set) var users: [User] = []
    @Published private(set) var feedItems: [MediaItem] = []
    @Published private(set) var isLoading = false

    var baseURL: String { serverSettings.fullURL }

    private let session: URLSession
    private var etag: String?
    private let decoder = JSONDecoder()

    private init() {
        serverSettings = ServerSettings.load()

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 10

        session = URLSession(configuration: configuration)
    }

    func fetchUsers() async {
        await setLoading(true)

        guard let request = makeRequest(path: "/api/users") else {
            await setLoading(false)
            return
        }

        do {
            let (data, response) = try await performRequest(request)
            try validateJSONResponse(response, data: data)

            do {
                let decodedResponse = try decoder.decode(UsersResponse.self, from: data)
                let users = await fetchUserProfiles(usernames: decodedResponse.users)

                await MainActor.run {
                    self.users = users.sorted { $0.username < $1.username }
                }
            } catch let decodingError as DecodingError {
                logDecodingError(decodingError, context: "fetchUsers", data: data)
            }
        } catch {
            logNetworkError(error, context: "fetchUsers")
        }

        await setLoading(false)
    }

    func fetchUserProfile(username: String) async -> User? {
        guard
            let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let request = makeRequest(path: "/api/users/\(encodedUsername)")
        else { return nil }

        do {
            let (data, response) = try await performRequest(request)
            try validateJSONResponse(response, data: data)

            do {
                let profileResponse = try decoder.decode(UserProfileResponse.self, from: data)
                prefetchAvatar(for: profileResponse.user)
                return profileResponse.user
            } catch let decodingError as DecodingError {
                logDecodingError(decodingError, context: "fetchUserProfile", data: data)
            }
        } catch {
            logNetworkError(error, context: "fetchUserProfile")
        }

        return nil
    }

    func fetchUserMedia(username: String) async -> [String: [MediaItem]] {
        guard
            let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            var request = makeRequest(path: "/api/users/\(encodedUsername)/media")
        else { return [:] }

        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await performRequest(request)

            if response.statusCode == 304 {
                return [:]
            }

            try validateJSONResponse(response, data: data)

            if let newEtag = response.value(forHTTPHeaderField: "ETag") {
                etag = newEtag
            }

            do {
                let flatResponse = try decoder.decode(FlatUserMediaResponse.self, from: data)
                let grouped = Dictionary(grouping: flatResponse.media, by: { $0.type })
                prefetchThumbnails(for: flatResponse.media)
                return grouped
            } catch let decodingError as DecodingError {
                logDecodingError(decodingError, context: "fetchUserMedia", data: data)
            }
        } catch {
            logNetworkError(error, context: "fetchUserMedia")
        }

        return [:]
    }

    func fetchRandomFeed(limit: Int = 30, mediaType: String? = nil) async {
        await setLoading(true)

        var queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let mediaType {
            queryItems.append(URLQueryItem(name: "type", value: mediaType))
        }

        guard let request = makeRequest(path: "/api/feed/random", queryItems: queryItems) else {
            await setLoading(false)
            return
        }

        do {
            let (data, response) = try await performRequest(request)
            try validateJSONResponse(response, data: data)

            do {
                let response = try decoder.decode(FeedResponse.self, from: data)
                let newItems = await MainActor.run { () -> [MediaItem] in
                    let existingIDs = Set(self.feedItems.map(\.uniqueID))
                    let freshItems = response.media.filter { !existingIDs.contains($0.uniqueID) }
                    self.feedItems.append(contentsOf: freshItems)
                    return freshItems
                }

                prefetchThumbnails(for: newItems)
            } catch let decodingError as DecodingError {
                logDecodingError(decodingError, context: "fetchRandomFeed", data: data)
            }
        } catch {
            logNetworkError(error, context: "fetchRandomFeed")
        }

        await setLoading(false)
    }

    func clearCache() async {
        await sendCacheCommand(endpoint: "/api/cache/clear")
        etag = nil
    }

    func refreshCache() async {
        await sendCacheCommand(endpoint: "/api/cache/refresh")
        etag = nil
    }

    @MainActor
    func resetFeed() {
        feedItems = []
    }
}

// MARK: - Helpers
private extension NetworkManager {
    func makeRequest(path: String, queryItems: [URLQueryItem]? = nil) -> URLRequest? {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: "\(baseURL)\(normalizedPath)") else {
            return nil
        }
        if let queryItems {
            components.queryItems = queryItems
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        return (data, httpResponse)
    }

    func validateJSONResponse(_ response: HTTPURLResponse, data: Data, acceptableStatusCodes: ClosedRange<Int> = 200...299) throws {
        guard acceptableStatusCodes.contains(response.statusCode) else {
            let preview = NetworkManager.preview(from: data)
            throw NetworkError.httpStatus(code: response.statusCode, preview: preview)
        }

        if let mimeType = response.value(forHTTPHeaderField: "Content-Type"),
           !mimeType.lowercased().contains("application/json"),
           !data.isEmpty {
            let preview = NetworkManager.preview(from: data)
            throw NetworkError.unexpectedContentType(mimeType: mimeType, preview: preview)
        }
    }

    func sendCacheCommand(endpoint: String) async {
        guard let request = makeRequest(path: endpoint) else { return }

        do {
            var commandRequest = request
            commandRequest.httpMethod = "POST"
            let (data, response) = try await performRequest(commandRequest)
            try validateJSONResponse(response, data: data)
        } catch {
            logNetworkError(error, context: "sendCacheCommand(\(endpoint))")
        }
    }

    func fetchUserProfiles(usernames: [String]) async -> [User] {
        await withTaskGroup(of: User?.self) { group in
            for username in usernames {
                group.addTask { [weak self] in
                    await self?.fetchUserProfile(username: username)
                }
            }

            var users: [User] = []
            for await user in group {
                if let user {
                    users.append(user)
                }
            }

            return users
        }
    }

    func prefetchAvatar(for user: User) {
        guard
            let avatar = user.avatar,
            let url = URL(string: "\(baseURL)\(avatar)")
        else { return }

        ImageCache.shared.prefetch(url: url)
    }

    func prefetchThumbnails(for items: [MediaItem]) {
        for item in items {
            guard
                let thumbnailPath = item.thumbnail,
                let url = URL(string: "\(baseURL)\(thumbnailPath)")
            else { continue }

            ImageCache.shared.prefetch(url: url)
        }
    }

    func logNetworkError(_ error: Error, context: String) {
        switch error {
        case NetworkError.httpStatus(let code, let preview):
            if preview.isEmpty {
                print("Network error [\(context)]: HTTP \(code)")
            } else {
                print("Network error [\(context)]: HTTP \(code) – preview: \(preview)")
            }
        case NetworkError.unexpectedContentType(let mimeType, let preview):
            if preview.isEmpty {
                print("Network error [\(context)]: Unexpected content type \(mimeType)")
            } else {
                print("Network error [\(context)]: Unexpected content type \(mimeType) – preview: \(preview)")
            }
        case NetworkError.invalidResponse:
            print("Network error [\(context)]: Invalid response")
        default:
            print("Network error [\(context)]: \(error)")
        }
    }

    func logDecodingError(_ error: DecodingError, context: String, data: Data) {
        let preview = NetworkManager.preview(from: data)
        if preview.isEmpty {
            print("Decoding error [\(context)]: \(error)")
        } else {
            print("Decoding error [\(context)]: \(error) – preview: \(preview)")
        }
    }

    static func preview(from data: Data) -> String {
        guard let string = String(data: data, encoding: .utf8) else { return "" }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.count > 200 {
            let index = trimmed.index(trimmed.startIndex, offsetBy: 200)
            return String(trimmed[..<index]) + "…"
        }

        return trimmed
    }

    func setLoading(_ value: Bool) async {
        await MainActor.run {
            isLoading = value
        }
    }
}

private enum NetworkError: Error {
    case invalidResponse
    case httpStatus(code: Int, preview: String)
    case unexpectedContentType(mimeType: String, preview: String)
}
