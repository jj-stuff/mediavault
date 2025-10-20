import SwiftUI
import UIKit

struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .transition(.opacity.combined(with: .scale))
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard !isLoading, image == nil, let url else { return }

        let cacheKey = url.isFileURL ? url.path : url.absoluteString

        if let cached = ImageCache.shared.image(forKey: cacheKey) {
            image = cached
            return
        }

        if url.isFileURL {
            do {
                let data = try Data(contentsOf: url)
                if let localImage = UIImage(data: data) {
                    let resized = localImage.resizedIfNeeded(maxDimension: 1024)
                    image = resized
                    ImageCache.shared.store(image: resized, forKey: cacheKey)
                }
            } catch {
                // ignore read failure
            }
            return
        }

        isLoading = true

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)

        if
            let cachedData = ImageCache.shared.cachedData(for: request),
            let cachedImage = UIImage(data: cachedData)
        {
            image = cachedImage.resizedIfNeeded(maxDimension: 1024)
            isLoading = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let downloaded = UIImage(data: data) else {
                isLoading = false
                return
            }

            let resized = downloaded.resizedIfNeeded(maxDimension: 1024)
            image = resized
            ImageCache.shared.store(image: resized, forKey: cacheKey)
            ImageCache.shared.store(data: data, response: response, for: request)
        } catch {
            // Swallow errors to avoid noisy logs; placeholder will remain visible.
        }

        isLoading = false
    }
}
