import Foundation

/// Decides where media comes from — a local folder or the server — and loads it.
///
/// This used to live as `onAppear` / `onChange` blocks in the root view and folder
/// handling in the settings screen, which meant the same three-step "resolve the
/// bookmark, scan, handle failure" sequence written out in several places.
@Observable
final class LibraryController {

    private(set) var localFolderURL: URL?

    private let scanner: MediaScannerService
    private let remote: RemoteServerService
    private let bookmarks: FolderBookmarkStore

    init(
        scanner: MediaScannerService,
        remote: RemoteServerService,
        bookmarks: FolderBookmarkStore
    ) {
        self.scanner = scanner
        self.remote = remote
        self.bookmarks = bookmarks
    }

    /// Root that every screen resolves relative paths against.
    ///
    /// In remote mode this is the server's `/api/files` base; locally it is the
    /// picked folder. Likes recorded in one mode therefore line up in the other,
    /// as long as both point at the same library.
    var activeRootURL: URL? {
        if remote.isEnabled && remote.isAuthenticated {
            return remote.filesBaseURL
        }
        return localFolderURL
    }

    var isRemoteMode: Bool { remote.isEnabled }

    // MARK: - Loading

    /// Loads whichever source is configured. Safe to call on every appearance.
    func load() async {
        if remote.isEnabled {
            await remote.checkAuth()
            guard remote.isAuthenticated else { return }
            await scanner.fetchFromRemote(service: remote)
        } else {
            guard let url = bookmarks.resolve() else { return }
            localFolderURL = url
            await scanner.scan(rootURL: url)
        }
    }

    /// Reloads after the user flips the remote toggle.
    func reloadAfterModeChange() async {
        scanner.clear()
        await load()
    }

    func refresh() async {
        if remote.isEnabled {
            await scanner.fetchFromRemote(service: remote)
        } else if let url = localFolderURL {
            await scanner.scan(rootURL: url)
        }
    }

    // MARK: - Local folder

    func selectFolder(_ url: URL) async {
        bookmarks.save(url)
        localFolderURL = url
        await scanner.scan(rootURL: url)
    }

    /// Forgets the folder. The user's files are untouched.
    func removeFolder() {
        bookmarks.clear()
        localFolderURL = nil
        scanner.clear()
    }
}
