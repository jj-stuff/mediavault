import AVFoundation

/// Configures the app's audio session once at launch.
///
/// Without this the session defaults to `.soloAmbient`, which silences all video
/// whenever the ring/silent switch is set to silent — surprising in an app whose
/// whole purpose is playing video. `.playback` is the category Apple documents for
/// media playback apps and is what makes audio survive the silent switch.
@Observable
final class AudioSessionController {

    private(set) var isConfigured = false

    func activate() {
        guard !isConfigured else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            isConfigured = true
        } catch {
            // Not fatal: playback still works, it just follows the silent switch.
            print("[MediaVault] Audio session setup failed: \(error)")
        }
    }
}
