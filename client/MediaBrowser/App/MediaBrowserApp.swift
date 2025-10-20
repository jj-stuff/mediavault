import SwiftUI

@main
struct MediaBrowserApp: App {
    @StateObject private var favoritesManager = FavoritesManager.shared
    @StateObject private var deletionManager = DeletionManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favoritesManager)
                .environmentObject(deletionManager)
                .preferredColorScheme(.dark)
        }
    }
}
