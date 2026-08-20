import SwiftUI

struct RootView: View {
    @Environment(LibraryController.self) private var library
    @Environment(RemoteServerService.self) private var remote
    @State private var selectedTab: AppTab = .profiles

    enum AppTab: Hashable {
        case profiles, forYou, liked, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Profiles", systemImage: "person.2.fill", value: .profiles) {
                ProfilesTab()
            }

            Tab("For You", systemImage: "play.square.stack.fill", value: .forYou) {
                ForYouTab()
            }

            Tab("Liked", systemImage: "heart.fill", value: .liked) {
                LikedTab()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task { await library.load() }
        .onChange(of: remote.isEnabled) {
            Task { await library.reloadAfterModeChange() }
        }
    }
}
