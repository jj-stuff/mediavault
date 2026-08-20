import AVFoundation
import SwiftUI

/// Loads and caches every image the UI displays — grid thumbnails and full-size
/// viewer images, local files and remote URLs alike.
///
/// This replaces three separate loading paths that had drifted apart: the thumbnail
/// service, and two hand-rolled copies of a downsampler in the feed and the viewer
/// that fetched remote images with a bare `URLSession` call and cached nothing, so
/// every scroll past an item re-downloaded it in full.
@Observable
final class ImageLoader {

    /// Longest edge for grid thumbnails, in points.
    static let thumbnailSize = CGSize(width: 200, height: 200)
    /// Longest edge for a full-screen image. Downsampling to this rather than
    /// decoding at native size is what keeps multi-megapixel JPEGs from tripping
    /// IOSurface allocation limits.
    static let fullImageMaxDimension: CGFloat = 3000
    /// Feed images are transient and numerous, so they get a tighter budget.
    static let feedImageMaxDimension: CGFloat = 2000

    // NSCache is internally synchronised; `nonisolated(unsafe)` opts it out of the
    // Sendable check rather than adding redundant locking around it.
    private nonisolated(unsafe) let thumbnailCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    /// Separate from the thumbnail cache so a burst of full-size images cannot
    /// evict the thumbnails backing the grid the user is about to scroll back to.
    private nonisolated(unsafe) let fullImageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 200 * 1024 * 1024
        return cache
    }()

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Thumbnails

    func thumbnail(for item: MediaItem, size: CGSize = ImageLoader.thumbnailSize) async -> UIImage? {
        let key = item.url as NSURL
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        let image: UIImage? = if item.isRemote {
            await remoteThumbnail(for: item)
        } else {
            await Self.localThumbnail(url: item.url, mediaType: item.mediaType, size: size)
        }

        if let image { thumbnailCache.setObject(image, forKey: key, cost: image.byteCount) }
        return image
    }

    // MARK: - Full-size images

    func fullImage(
        for url: URL,
        maxDimension: CGFloat = ImageLoader.fullImageMaxDimension
    ) async -> UIImage? {
        let key = url as NSURL
        if let cached = fullImageCache.object(forKey: key) { return cached }

        let image: UIImage? = if url.isFileURL {
            await Self.downsample(url: url, maxDimension: maxDimension)
        } else {
            await remoteImage(at: url, maxDimension: maxDimension)
        }

        if let image { fullImageCache.setObject(image, forKey: key, cost: image.byteCount) }
        return image
    }

    func clearCache() {
        thumbnailCache.removeAllObjects()
        fullImageCache.removeAllObjects()
    }

    // MARK: - Remote

    /// The server exposes thumbnails under `/api/thumbnails/...`, mirroring the
    /// `/api/files/...` path of the original. Asking for those rather than the full
    /// file is the difference between a few KB and a few MB per grid cell.
    private func remoteThumbnail(for item: MediaItem) async -> UIImage? {
        let source = item.url.absoluteString
        guard source.contains("/api/files/") else {
            return await remoteImage(at: item.url, maxDimension: Self.thumbnailSize.width * 2)
        }
        let thumbnailPath = source.replacingOccurrences(
            of: "/api/files/",
            with: "/api/thumbnails/"
        )
        guard let url = URL(string: thumbnailPath) else { return nil }
        return await remoteImage(at: url, maxDimension: nil)
    }

    private func remoteImage(at url: URL, maxDimension: CGFloat?) async -> UIImage? {
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let maxDimension else { return UIImage(data: data) }
            return await Self.downsample(data: data, maxDimension: maxDimension)
        } catch {
            return nil
        }
    }

    // MARK: - Decoding (off the main actor)

    @concurrent
    private static func localThumbnail(
        url: URL,
        mediaType: MediaItemType,
        size: CGSize
    ) async -> UIImage? {
        switch mediaType {
        case .image: imageThumbnail(url: url, size: size)
        case .video: videoThumbnail(url: url, size: size)
        }
    }

    @concurrent
    private static func downsample(url: URL, maxDimension: CGFloat) async -> UIImage? {
        // `kCGImageSourceShouldCache: false` keeps the full-resolution bitmap out of
        // memory; only the downsampled result is retained.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return thumbnail(from: source, maxPixelSize: maxDimension)
            ?? UIImage(contentsOfFile: url.path)
    }

    @concurrent
    private static func downsample(data: Data, maxDimension: CGFloat) async -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        return thumbnail(from: source, maxPixelSize: maxDimension) ?? UIImage(data: data)
    }

    nonisolated private static func thumbnail(
        from source: CGImageSource,
        maxPixelSize: CGFloat
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies the EXIF orientation tag, so portrait photos are upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func imageThumbnail(url: URL, size: CGSize) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: url.path)
        }
        // 2× the target so the image stays sharp on a Retina display.
        return thumbnail(from: source, maxPixelSize: max(size.width, size.height) * 2)
            ?? UIImage(contentsOfFile: url.path)
    }

    nonisolated private static func videoThumbnail(url: URL, size: CGSize) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)

        // One second in first: the opening frame of a video is very often black.
        for seconds in [1.0, 0.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
        }
        return nil
    }
}

private extension UIImage {
    /// Approximate decoded size, so NSCache's cost limit reflects real memory use
    /// rather than counting every image as 1.
    var byteCount: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
