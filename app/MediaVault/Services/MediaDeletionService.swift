import Foundation

/// The one place media gets deleted.
///
/// Previously this logic was copy-pasted into two views, which meant two subtly
/// different trash layouts, two chances to forget to update in-memory state, and
/// several failure paths that returned silently after the confirmation alert had
/// already been dismissed — the user saw a successful delete that never happened.
@Observable
final class MediaDeletionService {

    /// Folder that deleted items are moved into, relative to the library root.
    /// Matches TRASH_DIR_NAME in server/app/config.py.
    ///
    /// `nonisolated` because the background scan and the off-main trash move both
    /// read it from outside the main actor.
    nonisolated static let trashFolderName = "Trash"

    private let remote: RemoteServerService
    private let scanner: MediaScannerService
    private let likes: LikesService

    init(remote: RemoteServerService, scanner: MediaScannerService, likes: LikesService) {
        self.remote = remote
        self.scanner = scanner
        self.likes = likes
    }

    /// Moves `item` to the trash, locally or on the server, then reconciles the
    /// in-memory library and the like list.
    ///
    /// Throws rather than failing quietly: every caller presents the result.
    func delete(_ item: MediaItem, rootURL: URL?) async throws {
        guard let rootURL else { throw DeletionError.noLibraryRoot }

        if item.isRemote {
            try await deleteRemote(item, rootURL: rootURL)
        } else {
            try await moveToTrash(item, rootURL: rootURL)
        }

        // Both of these were previously missed on at least one delete path, leaving
        // the grid showing a file that no longer exists and a like pointing at it.
        scanner.removeItem(id: item.id)
        likes.unlike(mediaItem: item, rootURL: rootURL)
    }

    /// Deletes several items, and reports what did not go.
    ///
    /// Unlike the single-item `delete`, this does not throw: a selection of two
    /// hundred photos where one file has already been moved on the NAS should lose
    /// the other hundred and ninety-nine anyway, and then say what was left behind.
    ///
    /// Sequential on purpose. Each delete finishes by editing the scanner's library
    /// and the like list, and running them concurrently would interleave those edits
    /// for no gain: the disk, and the server, do one move at a time regardless.
    func delete(_ items: [MediaItem], rootURL: URL?) async -> BatchOutcome {
        var deleted = 0
        var failures: [String] = []

        for item in items {
            do {
                try await delete(item, rootURL: rootURL)
                deleted += 1
            } catch {
                failures.append("\(item.fileName): \(error.localizedDescription)")
            }
        }

        return BatchOutcome(deletedCount: deleted, failures: failures)
    }

    // MARK: - Remote

    private func deleteRemote(_ item: MediaItem, rootURL: URL) async throws {
        guard remote.isEnabled, remote.filesBaseURL != nil else {
            throw DeletionError.remoteNotConfigured
        }
        guard let path = MediaPath.strictRelative(for: item.url, under: rootURL) else {
            throw DeletionError.itemOutsideLibrary(item.fileName)
        }
        try await remote.deleteItem(path: path)
    }

    // MARK: - Local

    /// Moves the file into `<root>/Trash/<original/sub/path>`, off the main actor,
    /// falling back to an outright delete when the trash cannot be written.
    ///
    /// The original folder structure is preserved so `alice/1.jpg` and `bob/1.jpg`
    /// do not collide, and so a mistaken delete can be put back where it came from.
    /// This mirrors `_dispose` on the server, including the fallback: a read-only
    /// volume or a folder owned by someone else cannot have a `Trash` directory
    /// created inside it, and failing there means the delete the user confirmed
    /// twice simply does not happen. Deleting is what they asked for either way.
    @concurrent
    private func moveToTrash(_ item: MediaItem, rootURL: URL) async throws {
        guard let relativePath = MediaPath.strictRelative(for: item.url, under: rootURL) else {
            throw DeletionError.itemOutsideLibrary(item.fileName)
        }

        let fileManager = FileManager.default
        let destination = rootURL
            .appending(path: Self.trashFolderName)
            .appending(path: relativePath)

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(
                at: item.url,
                to: Self.availableURL(for: destination, fileManager: fileManager)
            )
        } catch {
            AppLog.library.notice(
                "trash unavailable (\(error.localizedDescription, privacy: .public)); deleting outright"
            )
            do {
                try fileManager.removeItem(at: item.url)
            } catch {
                throw DeletionError.moveFailed(error)
            }
        }
    }

    /// First unused name at `destination`, suffixing `_1`, `_2`, … on collision.
    ///
    /// The previous implementation suffixed a whole-second timestamp, so deleting
    /// two same-named files within the same second threw instead of renaming.
    nonisolated private static func availableURL(
        for destination: URL,
        fileManager: FileManager
    ) -> URL {
        guard fileManager.fileExists(atPath: destination.path) else { return destination }

        let folder = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var counter = 1

        while true {
            let name = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            let candidate = folder.appending(path: name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}

// MARK: - Results

extension MediaDeletionService {
    /// What a multi-item delete managed.
    struct BatchOutcome: Sendable {
        let deletedCount: Int
        /// One line per item that could not be deleted, already user-readable.
        let failures: [String]

        /// Nil when everything went, so a caller can present it or not without
        /// counting anything itself.
        var failureMessage: String? {
            guard !failures.isEmpty else { return nil }
            let heading = failures.count == 1
                ? "1 item could not be deleted."
                : "\(failures.count) items could not be deleted."
            // Capped: an alert listing two hundred failures is not readable, and the
            // reason is nearly always the same one repeated.
            return ([heading] + failures.prefix(5)).joined(separator: "\n")
        }
    }
}

// MARK: - Errors

extension MediaDeletionService {
    enum DeletionError: LocalizedError {
        case noLibraryRoot
        case remoteNotConfigured
        case itemOutsideLibrary(String)
        case moveFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noLibraryRoot:
                "No media folder is selected. Choose one in Settings first."
            case .remoteNotConfigured:
                "The server is not configured. Check the server URL in Settings."
            case .itemOutsideLibrary(let name):
                "\"\(name)\" is not inside the current media folder, so it was not deleted."
            case .moveFailed(let underlying):
                "Could not move the file to Trash: \(underlying.localizedDescription)"
            }
        }
    }
}
