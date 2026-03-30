import Foundation

/// Scans a root folder and discovers profiles (subfolders) with their media.
/// Runs on MainActor by default (Swift 6.2); heavy file I/O dispatched with @concurrent.
@Observable
final class MediaScannerService {
    var profiles: [MediaProfile] = []
    var isScanning: Bool = false
    var scanError: String?

    /// Keeps the security-scoped URL alive so all child URLs remain readable
    /// for lazy thumbnail loading, video playback, image viewing, etc.
    private var activeSecurityScopedURL: URL?

    func scan(rootURL: URL) async {
        isScanning = true
        scanError = nil
        profiles = []

        // Release previous access
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil

        guard rootURL.startAccessingSecurityScopedResource() else {
            scanError = "Unable to access the selected folder. Please try again."
            isScanning = false
            return
        }
        activeSecurityScopedURL = rootURL

        do {
            let scanned = try await performScan(rootURL: rootURL)
            profiles = scanned
        } catch {
            scanError = "Error scanning folder: \(error.localizedDescription)"
        }

        isScanning = false
    }

    /// Heavy file system work runs off the main actor.
    @concurrent
    private func performScan(rootURL: URL) async throws -> [MediaProfile] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var scannedProfiles: [MediaProfile] = []

        for itemURL in contents {
            let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues.isDirectory == true else { continue }

            let profile = scanProfileFolder(url: itemURL, fm: fm)
            if !profile.mediaItems.isEmpty {
                scannedProfiles.append(profile)
            }
        }

        scannedProfiles.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return scannedProfiles
    }

    nonisolated private func scanProfileFolder(url: URL, fm: FileManager) -> MediaProfile {
        let profileID = UUID()
        let profileName = url.lastPathComponent
        var mediaItems: [MediaItem] = []
        var subfolderNames: [String] = []

        mediaItems.append(contentsOf: collectMedia(in: url, profileID: profileID, profileName: profileName, subfolder: nil, fm: fm))

        if let subfolders = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for subfolder in subfolders {
                let rv = try? subfolder.resourceValues(forKeys: [.isDirectoryKey])
                guard rv?.isDirectory == true else { continue }
                let subName = subfolder.lastPathComponent
                subfolderNames.append(subName)
                mediaItems.append(contentsOf: collectMediaRecursively(in: subfolder, profileID: profileID, profileName: profileName, subfolder: subName, fm: fm))
            }
        }

        let thumbnailURL = mediaItems.filter { $0.mediaType == .image }.randomElement()?.url

        return MediaProfile(
            id: profileID, name: profileName, folderURL: url,
            thumbnailURL: thumbnailURL, mediaItems: mediaItems, subfolders: subfolderNames
        )
    }

    nonisolated private func collectMediaRecursively(in url: URL, profileID: UUID, profileName: String, subfolder: String?, fm: FileManager) -> [MediaItem] {
        var items = collectMedia(in: url, profileID: profileID, profileName: profileName, subfolder: subfolder, fm: fm)
        if let sub = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in sub {
                let rv = try? item.resourceValues(forKeys: [.isDirectoryKey])
                if rv?.isDirectory == true {
                    items.append(contentsOf: collectMediaRecursively(in: item, profileID: profileID, profileName: profileName, subfolder: subfolder ?? item.lastPathComponent, fm: fm))
                }
            }
        }
        return items
    }

    // MARK: In-memory mutation

    /// Removes a single item from all profiles without a full rescan.
    func removeItem(id: UUID) {
        for i in 0..<profiles.count {
            profiles[i].mediaItems.removeAll { $0.id == id }
        }
    }

    // MARK: Remote

    func fetchFromRemote(service: RemoteServerService) async {
        isScanning = true
        scanError = nil
        profiles = []
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
        do {
            profiles = try await service.fetchProfiles()
        } catch {
            scanError = error.localizedDescription
        }
        isScanning = false
    }

    nonisolated private func collectMedia(in directoryURL: URL, profileID: UUID, profileName: String, subfolder: String?, fm: FileManager) -> [MediaItem] {
        guard let files = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return files.compactMap { fileURL in
            guard let type = MediaItem.mediaType(for: fileURL.pathExtension) else { return nil }
            return MediaItem(
                id: UUID(), url: fileURL, fileName: fileURL.lastPathComponent,
                mediaType: type, profileID: profileID, profileName: profileName, subfolder: subfolder
            )
        }
    }
}
