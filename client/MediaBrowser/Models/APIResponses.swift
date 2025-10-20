import Foundation

struct UsersResponse: Codable {
    let success: Bool
    let users: [String]
}

struct UserProfileResponse: Codable {
    let success: Bool
    let user: User
}

struct FlatUserMediaResponse: Codable {
    let success: Bool
    let count: Int
    let media: [MediaItem]
}

struct FeedResponse: Codable {
    let success: Bool
    let media: [MediaItem]
}

struct DeletionListResponse: Codable {
    let success: Bool
    let paths: [String]
    let count: Int
    let location: String?
}
