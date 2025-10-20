import Foundation
import UIKit

final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let urlCache: URLCache
    private let queue = DispatchQueue(label: "image.cache.queue", qos: .userInitiated)

    private init() {
        memoryCache.countLimit = 250
        memoryCache.totalCostLimit = 100 * 1024 * 1024

        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let diskURL = cachesDirectory?.appendingPathComponent("ImageCache", isDirectory: true)
        urlCache = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024, directory: diskURL)
    }

    func image(forKey key: String) -> UIImage? {
        memoryCache.object(forKey: key as NSString)
    }

    func store(image: UIImage, forKey key: String) {
        let cost = image.diskCost
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func cachedData(for request: URLRequest) -> Data? {
        urlCache.cachedResponse(for: request)?.data
    }

    func store(data: Data, response: URLResponse, for request: URLRequest) {
        let cachedResponse = CachedURLResponse(response: response, data: data)
        urlCache.storeCachedResponse(cachedResponse, for: request)
    }

    func prefetch(url: URL) {
        let key = url.absoluteString

        if image(forKey: key) != nil { return }

        queue.async { [weak self] in
            guard let self else { return }

            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)

            if let data = self.cachedData(for: request), let image = UIImage(data: data) {
                let resized = image.resizedIfNeeded(maxDimension: 1024)
                self.store(image: resized, forKey: key)
                return
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                guard
                    error == nil,
                    let data,
                    let response,
                    let image = UIImage(data: data)
                else {
                    return
                }

                let resized = image.resizedIfNeeded(maxDimension: 1024)
                self.store(image: resized, forKey: key)
                self.store(data: data, response: response, for: request)
            }.resume()
        }
    }

    func clear() {
        memoryCache.removeAllObjects()
        urlCache.removeAllCachedResponses()
    }

    var diskUsage: Int {
        urlCache.currentDiskUsage
    }
}
