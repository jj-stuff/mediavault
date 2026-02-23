import SwiftUI
import AVFoundation

@Observable
final class ThumbnailService {
    static let shared = ThumbnailService()

    // NSCache is thread-safe by implementation; nonisolated(unsafe) suppresses the Sendable check.
    private nonisolated(unsafe) let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 500
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    private init() {}

    func thumbnail(for item: MediaItem, size: CGSize = CGSize(width: 200, height: 200)) async -> UIImage? {
        let key = item.url as NSURL
        if let cached = cache.object(forKey: key) { return cached }

        let image: UIImage?
        if item.url.scheme == "http" || item.url.scheme == "https" {
            image = await fetchRemoteThumbnail(item: item)
        } else {
            image = await generateThumbnail(url: item.url, mediaType: item.mediaType, size: size)
        }

        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Fetches thumbnail from the server's /api/thumbnails/ endpoint.
    /// The item URL points to /api/files/...; swap the path component to /api/thumbnails/.
    private func fetchRemoteThumbnail(item: MediaItem) async -> UIImage? {
        var urlStr = item.url.absoluteString
        urlStr = urlStr.replacingOccurrences(of: "/api/files/", with: "/api/thumbnails/")
        guard let url = URL(string: urlStr),
              let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        return UIImage(data: data)
    }

    /// Runs off the main actor for heavy image/video processing.
    @concurrent
    private func generateThumbnail(url: URL, mediaType: MediaItemType, size: CGSize) async -> UIImage? {
        switch mediaType {
        case .image:
            return Self.imageThumb(url: url, size: size)
        case .video:
            return Self.videoThumb(url: url, size: size)
        }
    }

    nonisolated private static func imageThumb(url: URL, size: CGSize) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * 2,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
            return img
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func videoThumb(url: URL, size: CGSize) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        for time in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
            if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    func clearCache() { cache.removeAllObjects() }
}
