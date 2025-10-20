import Foundation
import SwiftUI
import AVFoundation
import UIKit

final class LocalFileManager: ObservableObject {
    static let shared = LocalFileManager()

    @Published private(set) var mediaItems: [MediaItem] = []
    @Published private(set) var feedItems: [MediaItem] = []
    @Published private(set) var selectedFolder: URL?
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanError: Error?

    private let bookmarkKey = "localFolderBookmark"
    private let allowedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "webm",
        "jpg", "jpeg", "png", "gif", "bmp", "heic", "heif", "webp",
        "mp3", "wav", "m4a", "aac", "flac"
    ]

    private var securityScopedURL: URL?
    private let thumbnailQueue = DispatchQueue(label: "local.thumbnail.queue", qos: .userInitiated)

    private init() {
        restoreBookmark()
    }

    func updateSelectedFolder(_ url: URL) {
        stopAccessingCurrentFolder()

        guard url.startAccessingSecurityScopedResource() else {
            lastScanError = LocalFileError.securityScopeDenied
            return
        }

        securityScopedURL = url
        selectedFolder = url
        storeBookmark(for: url)
        refresh()
    }

    func refresh() {
        guard let folder = selectedFolder else { return }

        isScanning = true
        lastScanError = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            var collected: [MediaItem] = []

            do {
                if let enumerator = FileManager.default.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: nil
                ) {
                    for case let fileURL as URL in enumerator {
                        let resourceValues = try fileURL.resourceValues(forKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey,
                            .fileSizeKey,
                            .contentModificationDateKey
                        ])

                        if resourceValues.isDirectory == true {
                            continue
                        }

                        guard resourceValues.isRegularFile == true else {
                            continue
                        }

                        let ext = fileURL.pathExtension.lowercased()
                        guard allowedExtensions.contains(ext) else { continue }

                        let relativePath = fileURL.path.replacingOccurrences(
                            of: folder.path,
                            with: ""
                        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                        let pseudoUser: String
                        if let firstComponent = relativePath.split(separator: "/").first, !firstComponent.isEmpty {
                            pseudoUser = String(firstComponent)
                        } else {
                            pseudoUser = folder.lastPathComponent.isEmpty ? "Local" : folder.lastPathComponent
                        }

                        let mediaItem = MediaItem(
                            name: fileURL.lastPathComponent,
                            path: relativePath,
                            url: fileURL.absoluteString,
                            fullPath: fileURL.path,
                            size: resourceValues.fileSize ?? 0,
                            type: ext,
                            username: pseudoUser,
                            thumbnail: nil,
                            modified: resourceValues.contentModificationDate
                        )

                        collected.append(mediaItem)
                    }
                }

                collected.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                let arranged = NetworkManager.arrangeFeed(collected.shuffled())

                await MainActor.run {
                    self.feedItems = arranged
                    self.mediaItems = collected
                    self.isScanning = false
                }
            } catch {
                await MainActor.run {
                    self.lastScanError = error
                    self.isScanning = false
                }
            }
        }
    }

    func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var isStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                return
            }

            guard url.startAccessingSecurityScopedResource() else {
                lastScanError = LocalFileError.securityScopeDenied
                return
            }

            securityScopedURL = url
            selectedFolder = url
            refresh()
        } catch {
            lastScanError = error
        }
    }

    private func storeBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData()
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            lastScanError = error
        }
    }

    private func stopAccessingCurrentFolder() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    func clearSelection() {
        stopAccessingCurrentFolder()
        selectedFolder = nil
        mediaItems = []
        feedItems = []
        isScanning = false
        lastScanError = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    func thumbnail(for item: MediaItem, maxDimension: CGFloat = 120) async -> UIImage? {
        let key = "local-thumb-\(item.uniqueID)-\(Int(maxDimension))"

        if let cached = ImageCache.shared.image(forKey: key) {
            return cached
        }

        guard let url = item.resolvedURL else { return nil }

        return await withCheckedContinuation { continuation in
            thumbnailQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                var generated: UIImage?

                if item.isVideo {
                    let asset = AVAsset(url: url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

                    if let cgImage = try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) {
                        generated = UIImage(cgImage: cgImage)
                    }
                } else if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    generated = image
                }

                if let generated {
                    let resized = generated.resizedIfNeeded(maxDimension: max(maxDimension, 1))
                    ImageCache.shared.store(image: resized, forKey: key)
                    continuation.resume(returning: resized)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

enum LocalFileError: Error {
    case securityScopeDenied
}
