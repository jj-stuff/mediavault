import Foundation

struct ServerSettings: Codable, Equatable {
    var address: String = "http://192.168.1.123:3000"

    var fullURL: String { Self.normalizedAddress(address) }

    private static let storageKey = "ServerSettings"

    init(address: String = "http://192.168.1.123:3000") {
        self.address = address
    }

    func normalized() -> ServerSettings {
        ServerSettings(address: Self.normalizedAddress(address))
    }

    func save() {
        let normalizedSettings = normalized()
        guard let encoded = try? JSONEncoder().encode(normalizedSettings) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.storageKey)
    }

    static func load() -> ServerSettings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(ServerSettings.self, from: data)
        else {
            return ServerSettings()
        }

        return settings.normalized()
    }

    static func normalizedAddress(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "http://localhost:3000"
        }

        if !trimmed.contains("://") {
            trimmed = "http://\(trimmed)"
        }

        guard var components = URLComponents(string: trimmed) else {
            return "http://localhost:3000"
        }

        components.scheme = components.scheme?.lowercased()

        if components.port == nil,
           let scheme = components.scheme,
           scheme == "http",
           let host = components.host,
           isLikelyLocalHost(host) {
            components.port = 3000
        }

        let normalizedURL = components.url?.absoluteString ?? trimmed
        var final = normalizedURL

        while final.count > 1, final.hasSuffix("/") {
            final.removeLast()
        }

        return final
    }
}

extension ServerSettings {
    private enum CodingKeys: String, CodingKey {
        case address
        case scheme
        case host
        case port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let decodedAddress = try container.decodeIfPresent(String.self, forKey: .address) {
            address = decodedAddress
            return
        }

        let scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? "http"
        let host = try container.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        let port = try container.decodeIfPresent(String.self, forKey: .port)

        if let port, !port.isEmpty {
            address = "\(scheme)://\(host):\(port)"
        } else {
            address = "\(scheme)://\(host)"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(address, forKey: .address)
    }
}

private extension ServerSettings {
    static func isLikelyLocalHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()

        if ["localhost", "::1", "0.0.0.0"].contains(lowercased) {
            return true
        }

        if lowercased.hasSuffix(".local") {
            return true
        }

        if lowercased.hasPrefix("127.") || lowercased.hasPrefix("169.254.") {
            return true
        }

        if lowercased.hasPrefix("10.") || lowercased.hasPrefix("192.168.") {
            return true
        }

        if lowercased.hasPrefix("172.") {
            let octets = lowercased.split(separator: ".")
            if octets.count > 1, let second = Int(octets[1]), (16...31).contains(second) {
                return true
            }
        }

        if lowercased.contains(":") {
            return true
        }

        return false
    }
}
