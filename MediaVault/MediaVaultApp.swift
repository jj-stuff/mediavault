import SwiftUI

@main
struct MediaVaultApp: App {
    @State private var scanner = MediaScannerService()
    @State private var likesService = LikesService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(likesService)
        }
    }
}
