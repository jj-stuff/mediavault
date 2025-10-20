import Foundation

struct User: Identifiable, Codable, Hashable {
    let username: String
    let avatar: String?
    let mediaCount: Int

    var id: String { username }
}
