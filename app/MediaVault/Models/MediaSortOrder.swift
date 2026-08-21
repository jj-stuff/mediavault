import Foundation

/// How a list of media is ordered on screen.
///
/// One type, used by the profile grid, the subfolder grid, and the Liked grid, so
/// the three cannot drift into three different notions of "newest".
nonisolated enum MediaSortOrder: String, CaseIterable, Identifiable, Sendable {
    case nameAscending
    case nameDescending
    case newest
    case oldest
    case largest
    case smallest

    var id: Self { self }

    var label: String {
        switch self {
        case .nameAscending: "Name (A–Z)"
        case .nameDescending: "Name (Z–A)"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .largest: "Largest First"
        case .smallest: "Smallest First"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAscending, .nameDescending: "textformat"
        case .newest, .oldest: "calendar"
        case .largest, .smallest: "internaldrive"
        }
    }

    /// Sorts a copy of `items`.
    ///
    /// Every comparison falls back to the file name when the primary key ties or is
    /// missing, so the order is total and stable — a grid that reshuffles items with
    /// no timestamp on every redraw is worse than one that ignores the sort.
    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        func byName(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
            lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }

        return switch self {
        case .nameAscending:
            items.sorted(by: byName)
        case .nameDescending:
            items.sorted { byName($1, $0) }
        case .newest:
            items.sorted {
                let (a, b) = ($0.modifiedAt ?? .distantPast, $1.modifiedAt ?? .distantPast)
                return a == b ? byName($0, $1) : a > b
            }
        case .oldest:
            items.sorted {
                let (a, b) = ($0.modifiedAt ?? .distantFuture, $1.modifiedAt ?? .distantFuture)
                return a == b ? byName($0, $1) : a < b
            }
        case .largest:
            items.sorted {
                let (a, b) = ($0.byteSize ?? 0, $1.byteSize ?? 0)
                return a == b ? byName($0, $1) : a > b
            }
        case .smallest:
            items.sorted {
                let (a, b) = ($0.byteSize ?? .max, $1.byteSize ?? .max)
                return a == b ? byName($0, $1) : a < b
            }
        }
    }
}
