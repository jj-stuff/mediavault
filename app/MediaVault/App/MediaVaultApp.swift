import SwiftUI

@main
struct MediaVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies.scanner)
                .environment(dependencies.likes)
                .environment(dependencies.remote)
                .environment(dependencies.imageLoader)
                .environment(dependencies.deletion)
                .environment(dependencies.library)
                .environment(dependencies.orientation)
                .environment(dependencies.feed)
                .environment(dependencies.playerPool)
                .task { dependencies.audioSession.activate() }
        }
    }
}
