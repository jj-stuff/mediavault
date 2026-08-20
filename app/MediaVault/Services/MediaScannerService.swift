import Foundation

/// Discovers profiles and their media, from a local folder or the remote server.
///
/// Mirrors the scan in `server/app/library.py`: each immediate subfolder of the root
/// is a profile, media sitting directly in it has no subfolder, and everything below
/// that is attributed to its top-level subfolder name.
@Observable
final class MediaScannerService {
    private(set) var profiles: [MediaProfile] = []
    private(set) var isScanning = false
    private(set) var scanError: String?

    /// Holds the security-scoped URL open for the whole session.
    ///
    /// Scoped access has to stay open, not be released once the scan finishes:
    /// thumbnails, video playback, and full-size images all resolve child URLs
    /// lazily, long after the scan is done.
    ///
    /// Released in `scan` and `clear` rather than in `deinit`: this service is owned
    /// by the composition root and lives as long as the app does, so a deinit would
    /// never actually run.
    private var activeSecurityScopedURL: URL?

    // MARK: - Local scanning

    func scan(rootURL: URL) async {
        isScanning = true
        scanError = nil
        profiles = []

        releaseScopedAccess()

        guard rootURL.startAccessingSecurityScopedResource() else {
            scanError = "Unable to access the selected folder. Please pick it again in Settings."
            isScanning = false
            return
        }
        activeSecurityScopedURL = rootURL

        do {
            profiles = try await Self.performScan(rootURL: rootURL)
        } catch {
            scanError = "Error scanning folder: \(error.localizedDescription)"
        }

        isScanning = false
    }

    // MARK: - Remote

    func fetchFromRemote(service: RemoteServerService) async {
        isScanning = true
        scanError = nil
        profiles = []
        releaseScopedAccess()

        do {
            profiles = try await service.fetchProfiles()
        } catch {
            scanError = error.localizedDescription
        }

        isScanning = false
    }

    // MARK: - In-memory mutation

    /// Drops one item from every profile without a full rescan.
    func removeItem(id: UUID) {
        for index in profiles.indices {
            profiles[index].mediaItems.removeAll { $0.id == id }
        }
    }

    func clear() {
        profiles = []
        scanError = nil
        releaseScopedAccess()
    }

    private func releaseScopedAccess() {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
    }

    // MARK: - Filesystem walk (off the main actor)

    @concurrent
    private static func performScan(rootURL: URL) async throws -> [MediaProfile] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var scanned: [MediaProfile] = []
        for url in contents where url.isDirectory {
            // Deleted items live here; showing them back as a profile would make
            // "move to Trash" look like it did nothing.
            guard url.lastPathComponent != MediaDeletionService.trashFolderName else { continue }

            let profile = scanProfileFolder(url: url, fileManager: fileManager)
            if !profile.mediaItems.isEmpty { scanned.append(profile) }
        }

        scanned.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return scanned
    }

    nonisolated private static func scanProfileFolder(
        url: URL,
        fileManager: FileManager
    ) -> MediaProfile {
        let profileID = UUID()
        let profileName = url.lastPathComponent

        // One directory listing, split into files and folders. The previous version
        // listed the same directory twice per profile.
        let entries = contentsOf(url, fileManager: fileManager)
        var mediaItems = entries.files.compactMap {
            makeItem(url: $0, profileID: profileID, profileName: profileName, subfolder: nil)
        }

        var subfolderNames: [String] = []
        for folder in entries.folders {
            let name = folder.lastPathComponent
            subfolderNames.append(name)
            mediaItems.append(contentsOf: collectRecursively(
                in: folder,
                profileID: profileID,
                profileName: profileName,
                subfolder: name,
                fileManager: fileManager
            ))
        }

        return MediaProfile(
            id: profileID,
            name: profileName,
            folderURL: url,
            thumbnailURL: mediaItems.first { $0.mediaType == .image }?.url ?? mediaItems.first?.url,
            mediaItems: mediaItems,
            subfolders: subfolderNames
        )
    }

    nonisolated private static func collectRecursively(
        in url: URL,
        profileID: UUID,
        profileName: String,
        subfolder: String,
        fileManager: FileManager
    ) -> [MediaItem] {
        let entries = contentsOf(url, fileManager: fileManager)
        var items = entries.files.compactMap {
            makeItem(url: $0, profileID: profileID, profileName: profileName, subfolder: subfolder)
        }
        for folder in entries.folders {
            items.append(contentsOf: collectRecursively(
                in: folder,
                profileID: profileID,
                profileName: profileName,
                subfolder: subfolder,
                fileManager: fileManager
            ))
        }
        return items
    }

    nonisolated private static func contentsOf(
        _ url: URL,
        fileManager: FileManager
    ) -> (files: [URL], folders: [URL]) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        let sorted = contents.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        return (sorted.filter { !$0.isDirectory }, sorted.filter { $0.isDirectory })
    }

    nonisolated private static func makeItem(
        url: URL,
        profileID: UUID,
        profileName: String,
        subfolder: String?
    ) -> MediaItem? {
        guard let type = MediaItem.mediaType(for: url.pathExtension) else { return nil }
        return MediaItem(
            id: UUID(),
            url: url,
            fileName: url.lastPathComponent,
            mediaType: type,
            profileID: profileID,
            profileName: profileName,
            subfolder: subfolder
        )
    }
}

// `nonisolated` so the background scan can use it; an extension does not inherit
// the target's default isolation from the type it extends.
nonisolated private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
