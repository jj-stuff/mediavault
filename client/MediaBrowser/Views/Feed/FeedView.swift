import SwiftUI

struct FeedView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @State private var mediaFilter: MediaFilter = .all
    @State private var isRequestInFlight = false
    @State private var visibleIndex: Int?

    private let screenBounds = UIScreen.main.bounds

    var body: some View {
        ZStack {
            if networkManager.feedItems.isEmpty && !networkManager.isLoading {
                emptyState
            } else {
                feedScrollView
            }

            filterBar

            if networkManager.isLoading && networkManager.feedItems.isEmpty {
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
        .task {
            if networkManager.feedItems.isEmpty {
                await networkManager.fetchRandomFeed(limit: 30, mediaType: mediaFilter.apiValue)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("No media available")
                .foregroundColor(.secondary)
        }
    }

    private var feedScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(networkManager.feedItems.enumerated()), id: \.element.id) { index, item in
                    FeedItemView(
                        item: item,
                        isVisible: visibleIndex == index
                    )
                    .environmentObject(favoritesManager)
                    .environmentObject(deletionManager)
                    .frame(width: screenBounds.width, height: screenBounds.height)
                    .onAppear {
                        visibleIndex = index
                        loadMoreItemsIfNeeded(currentIndex: index)
                    }
                    .onDisappear {
                        if visibleIndex == index {
                            visibleIndex = nil
                        }
                    }
                }
            }
        }
        .scrollTargetBehavior(.paging)
        .ignoresSafeArea()
    }

    private var filterBar: some View {
        VStack {
            HStack {
                ForEach(MediaFilter.allCases, id: \.self) { filter in
                    Button {
                        switchToFilter(filter)
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 14, weight: mediaFilter == filter ? .bold : .medium))
                            .foregroundColor(mediaFilter == filter ? .black : .white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(mediaFilter == filter ? Color.white : Color.black.opacity(0.5))
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.4))
            .cornerRadius(25)
            .padding(.horizontal)
            .padding(.top, 55)

            Spacer()
        }
    }

    private func switchToFilter(_ filter: MediaFilter) {
        guard mediaFilter != filter else { return }
        mediaFilter = filter

        Task {
            await MainActor.run {
                networkManager.resetFeed()
            }
            await networkManager.fetchRandomFeed(limit: 30, mediaType: filter.apiValue)
        }
    }

    private func loadMoreItemsIfNeeded(currentIndex: Int) {
        guard !isRequestInFlight else { return }
        let threshold = networkManager.feedItems.count - 5

        if currentIndex >= threshold {
            isRequestInFlight = true

            Task {
                await networkManager.fetchRandomFeed(limit: 30, mediaType: mediaFilter.apiValue)
                isRequestInFlight = false
            }
        }
    }
}

extension FeedView {
    enum MediaFilter: String, CaseIterable {
        case all = "All"
        case photos = "Photos"
        case videos = "Videos"

        var apiValue: String? {
            switch self {
            case .all: return nil
            case .photos: return "image"
            case .videos: return "video"
            }
        }
    }
}
