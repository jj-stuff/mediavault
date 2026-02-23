import Foundation

/// Pure algorithm, no UI state — explicitly nonisolated.
nonisolated enum ForYouAlgorithm {

    static func generateFeed(
        from profiles: [MediaProfile],
        batchSize: Int = 50,
        excludeIDs: Set<UUID> = []
    ) -> [MediaItem] {
        guard !profiles.isEmpty else { return [] }

        var profileQueues: [UUID: [MediaItem]] = [:]
        for profile in profiles {
            let available = profile.mediaItems.filter { !excludeIDs.contains($0.id) }.shuffled()
            if !available.isEmpty { profileQueues[profile.id] = available }
        }
        guard !profileQueues.isEmpty else { return [] }

        var feed: [MediaItem] = []
        var lastProfileIDs: [UUID] = []
        let minGap = max(2, min(profileQueues.count - 1, 5))
        var iterations = 0
        let maxIterations = batchSize * 3

        while feed.count < batchSize && iterations < maxIterations {
            iterations += 1
            let recentSet = Set(lastProfileIDs.suffix(minGap))
            var eligible = profileQueues.keys.filter { !recentSet.contains($0) }
            if eligible.isEmpty { eligible = Array(profileQueues.keys) }

            let weights = eligible.compactMap { id -> (UUID, Int)? in
                guard let q = profileQueues[id], !q.isEmpty else { return nil }
                return (id, q.count)
            }
            guard !weights.isEmpty else { break }

            let total = weights.reduce(0) { $0 + $1.1 }
            var rand = Int.random(in: 0..<total)
            var selectedID: UUID?
            for (id, w) in weights {
                rand -= w
                if rand < 0 { selectedID = id; break }
            }

            guard let pid = selectedID, var q = profileQueues[pid], !q.isEmpty else { continue }
            feed.append(q.removeFirst())
            lastProfileIDs.append(pid)
            if q.isEmpty { profileQueues.removeValue(forKey: pid) } else { profileQueues[pid] = q }
            if profileQueues.isEmpty { break }
        }
        return feed
    }

    static func generateNextBatch(from profiles: [MediaProfile], currentFeed: [MediaItem], batchSize: Int = 30) -> [MediaItem] {
        let shown = Set(currentFeed.map { $0.id })
        let newItems = generateFeed(from: profiles, batchSize: batchSize, excludeIDs: shown)
        return newItems.isEmpty ? generateFeed(from: profiles, batchSize: batchSize) : newItems
    }
}
