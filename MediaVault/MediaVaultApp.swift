import SwiftUI

@main
struct MediaVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var scanner = MediaScannerService()
    @State private var likesService = LikesService()
    @State private var remoteService = RemoteServerService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(likesService)
                .environment(remoteService)
        }
    }
}
