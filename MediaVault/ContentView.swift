import SwiftUI

struct ContentView: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LikesService.self) private var likesService
    @State private var selectedTab: AppTab = .profiles
    @State private var rootFolderURL: URL?

    enum AppTab: Hashable {
        case profiles, forYou, liked, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Profiles", systemImage: "person.2.fill", value: .profiles) {
                ProfilesTab(rootURL: rootFolderURL)
            }

            Tab("For You", systemImage: "play.square.stack.fill", value: .forYou) {
                ForYouTab(rootURL: rootFolderURL)
            }

            Tab("Liked", systemImage: "heart.fill", value: .liked) {
                LikedTab(rootURL: rootFolderURL)
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsTab(rootFolderURL: $rootFolderURL)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onAppear {
            if let savedURL = FolderBookmarkResolver.resolveBookmark() {
                rootFolderURL = savedURL
                Task { await scanner.scan(rootURL: savedURL) }
            }
        }
    }
}
