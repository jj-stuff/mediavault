import Foundation
import os

/// The app's loggers, declared in one place.
///
/// `os.Logger` rather than `print`: these stay compiled into every build but cost
/// almost nothing until something is listening, and they can be filtered instead of
/// drowning the console. In Xcode's console or Console.app, filter on
/// `subsystem:com.mediavault.app`, and add `category:playback` to watch the feed's
/// player pool alone.
nonisolated enum AppLog {
    private static let subsystem = "com.mediavault.app"

    /// Feed contents, scroll position, and pagination.
    static let feed = Logger(subsystem: subsystem, category: "feed")

    /// The player pool: which `AVPlayer` exists, which one is allowed to make sound.
    /// Worth its own category because three independent things have to agree here —
    /// SwiftUI's scroll position, the feed array, and a pool that lives outside the
    /// view tree — and when they disagree the symptom is "the wrong video is playing".
    static let playback = Logger(subsystem: subsystem, category: "playback")

    /// Scanning, refreshing, and deleting.
    static let library = Logger(subsystem: subsystem, category: "library")
}

nonisolated extension UUID {
    /// First block of the UUID — enough to follow one item through a log, short
    /// enough that a line stays readable.
    var short: String { String(uuidString.prefix(8)) }
}
