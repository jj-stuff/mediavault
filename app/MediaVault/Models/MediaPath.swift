import Foundation

/// Converts media URLs to and from paths relative to the library root.
///
/// The same item is addressed three different ways across the app — as a file URL
/// under a security-scoped folder, as an HTTPS URL under the server's `/api/files`
/// base, and as a stored like — so every comparison has to happen in one normalised
/// form. This is that form. It is the single place the conversion lives.
nonisolated enum MediaPath {

    /// Path of `url` relative to `root`, with no leading slash.
    ///
    /// Works for both file and remote URLs because `URL.path` strips the scheme and
    /// host, leaving `/api/files/alice/x.jpg` against a root of `/api/files`.
    /// Falls back to the last path component when `url` is not under `root` at all,
    /// which keeps a mismatched root from producing a path that silently resolves
    /// somewhere unexpected.
    static func relative(for url: URL, under root: URL) -> String {
        let fullPath = url.path
        let rootPath = root.path
        let raw = fullPath.hasPrefix(rootPath)
            ? String(fullPath.dropFirst(rootPath.count))
            : url.lastPathComponent
        return normalize(raw)
    }

    /// Like `relative(for:under:)`, but `nil` rather than a fallback when `url` is
    /// not actually under `root`.
    ///
    /// Destructive operations must use this one. The lenient fallback would turn
    /// `alice/photo.jpg` into a bare `photo.jpg`, and a delete built from that path
    /// would target the wrong file.
    static func strictRelative(for url: URL, under root: URL) -> String? {
        let fullPath = url.path
        let rootPath = root.path
        guard fullPath.hasPrefix(rootPath) else { return nil }
        let relative = normalize(String(fullPath.dropFirst(rootPath.count)))
        return relative.isEmpty ? nil : relative
    }

    /// Strips a leading slash so paths built by different code paths compare equal.
    static func normalize(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}
