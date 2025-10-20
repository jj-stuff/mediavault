import SwiftUI

@main
struct MediaBrowserApp: App {
    @StateObject private var favoritesManager = FavoritesManager.shared
    @StateObject private var deletionManager = DeletionManager.shared
    @StateObject private var localManager = LocalFileManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(favoritesManager)
                .environmentObject(deletionManager)
                .environmentObject(localManager)
                .preferredColorScheme(.dark)
        }
    }
}
