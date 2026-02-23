import SwiftUI

struct ContentView: View {
    @Environment(MediaScannerService.self) private var scanner
    @Environment(LikesService.self) private var likesService
    @Environment(RemoteServerService.self) private var remoteService
    @State private var selectedTab: AppTab = .profiles
    @State private var localFolderURL: URL?

    enum AppTab: Hashable {
        case profiles, forYou, liked, settings
    }

    /// Root URL passed to all tabs for likes resolution.
    /// Remote mode uses the server's /api/files base; local uses the picked folder.
    var activeRootURL: URL? {
        if remoteService.isEnabled && remoteService.isAuthenticated {
            return remoteService.filesBaseURL
        }
        return localFolderURL
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Profiles", systemImage: "person.2.fill", value: .profiles) {
                ProfilesTab(rootURL: activeRootURL)
            }

            Tab("For You", systemImage: "play.square.stack.fill", value: .forYou) {
                ForYouTab(rootURL: activeRootURL)
            }

            Tab("Liked", systemImage: "heart.fill", value: .liked) {
                LikedTab(rootURL: activeRootURL)
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsTab(rootFolderURL: $localFolderURL)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onAppear {
            if remoteService.isEnabled {
                Task {
                    await remoteService.checkAuth()
                    if remoteService.isAuthenticated {
                        await scanner.fetchFromRemote(service: remoteService)
                    }
                }
            } else if let savedURL = FolderBookmarkResolver.resolveBookmark() {
                localFolderURL = savedURL
                Task { await scanner.scan(rootURL: savedURL) }
            }
        }
        .onChange(of: remoteService.isEnabled) { _, enabled in
            scanner.profiles = []
            if enabled {
                Task {
                    await remoteService.checkAuth()
                    if remoteService.isAuthenticated {
                        await scanner.fetchFromRemote(service: remoteService)
                    }
                }
            } else if let savedURL = FolderBookmarkResolver.resolveBookmark() {
                localFolderURL = savedURL
                Task { await scanner.scan(rootURL: savedURL) }
            }
        }
    }
}
