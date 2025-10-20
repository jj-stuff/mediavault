import SwiftUI

struct ContentView: View {
    @StateObject private var networkManager = NetworkManager.shared
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var deletionManager: DeletionManager
    @State private var selectedTab = 1

    var body: some View {
        TabView(selection: $selectedTab) {
            UsersListView()
                .tabItem {
                    Image(systemName: "person.3.fill")
                    Text("Users")
                }
                .tag(0)

            FeedView()
                .tabItem {
                    Image(systemName: "play.rectangle.fill")
                    Text("Feed")
                }
                .tag(1)

            LikedView()
                .tabItem {
                    Image(systemName: "heart.fill")
                    Text("Liked")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(3)
        }
        .environmentObject(favoritesManager)
        .environmentObject(deletionManager)
        .task {
            await deletionManager.loadDeletionList()
        }
    }
}
