import AVKit
import SwiftUI

/// Full-screen video with a scrubber, double-tap skip zones, and press-to-speed-up.
struct VideoContentView: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var isLandscape = false

    var body: some View {
        EnhancedVideoPlayerView(
            url: url,
            player: $player,
            skipDuration: 10,
            isLandscape: $isLandscape,
            shouldPlay: true
        )
        .ignoresSafeArea()
        .onDisappear {
            player?.pause()
            // Detaching the item releases the decoder; without it a long paging
            // session leaves a pile of players holding video pipelines open.
            player?.replaceCurrentItem(with: nil)
        }
    }
}
