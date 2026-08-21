import Foundation

/// A narrow slice of `UserDefaults`, covering only what this app stores.
///
/// Depending on the protocol rather than `UserDefaults.standard` directly means the
/// backing store is a decision made once at the composition root: `.standard` for
/// the app, a suite for a future widget or share extension, an in-memory double in
/// tests. Nothing downstream changes when it moves.
protocol KeyValueStore: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool

    func write(_ data: Data?, forKey key: String)
    func write(_ string: String?, forKey key: String)
    func write(_ flag: Bool, forKey key: String)
    func remove(forKey key: String)
}

// `data(forKey:)`, `string(forKey:)`, and `bool(forKey:)` already match, so only the
// writers need bridging — `UserDefaults.set` takes `Any?` and cannot satisfy a
// requirement typed on `Data?` or `String?`.
extension UserDefaults: KeyValueStore {
    func write(_ data: Data?, forKey key: String) { set(data, forKey: key) }
    func write(_ string: String?, forKey key: String) { set(string, forKey: key) }
    func write(_ flag: Bool, forKey key: String) { set(flag, forKey: key) }
    func remove(forKey key: String) { removeObject(forKey: key) }
}

/// Storage keys, named in one place so a typo cannot silently orphan stored data.
nonisolated enum StorageKey {
    static let likedItems = "likedMediaItems"
    static let folderBookmark = "selectedFolderBookmark"
    static let remoteEnabled = "remoteEnabled"
    static let remoteServerURL = "remoteServerURL"
    static let remoteLibraryRoot = "remoteLibraryRoot"
    static let flattenFolders = "flattenFolders"
    static let mediaSortOrder = "mediaSortOrder"
    static let profileSortOrder = "profileSortOrder"
}
