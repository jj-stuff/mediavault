import Foundation

/// The composition root.
///
/// Every shared service is built exactly once, here, and handed down through the
/// environment. There are no `.shared` singletons: each of these is a single
/// instance because this type creates one, not because the type forbids a second.
/// That is what lets a test — or a future widget or share extension — assemble the
/// same graph with a different store or a stubbed server.
@Observable
final class AppDependencies {
    let store: KeyValueStore
    let bookmarks: FolderBookmarkStore
    let scanner: MediaScannerService
    let likes: LikesService
    let remote: RemoteServerService
    let imageLoader: ImageLoader
    let deletion: MediaDeletionService
    let library: LibraryController
    let orientation: OrientationController
    let audioSession: AudioSessionController
    let feed: ForYouFeedModel
    let playerPool: FeedPlayerPool

    /// - Parameter store: swap for an in-memory double in tests, or a
    ///   `UserDefaults(suiteName:)` App Group when an extension needs the same data.
    init(store: KeyValueStore = UserDefaults.standard) {
        self.store = store

        let bookmarks = FolderBookmarkStore(store: store)
        let scanner = MediaScannerService()
        let likes = LikesService(store: store)
        let remote = RemoteServerService(store: store)

        self.bookmarks = bookmarks
        self.scanner = scanner
        self.likes = likes
        self.remote = remote
        self.imageLoader = ImageLoader()
        self.deletion = MediaDeletionService(remote: remote, scanner: scanner, likes: likes)
        self.library = LibraryController(scanner: scanner, remote: remote, bookmarks: bookmarks)
        self.orientation = OrientationController()
        self.audioSession = AudioSessionController()
        self.feed = ForYouFeedModel()
        self.playerPool = FeedPlayerPool()
    }
}
