import Foundation

public struct MetadataPreferences: Sendable, Equatable, Codable {
    /// ISO country codes in preference order (e.g. ["NL", "DE", "GB", "US"]).
    public var preferredCountries: [String]
    /// Auto-pick the best match when its confidence reaches this threshold.
    public var autoPickThreshold: Double

    public init(preferredCountries: [String] = [], autoPickThreshold: Double = 0.75) {
        self.preferredCountries = preferredCountries
        self.autoPickThreshold = autoPickThreshold
    }
}

/// Ranks candidate releases for a disc. Pure scoring, fully testable.
public struct ReleaseScorer: Sendable {
    public let preferences: MetadataPreferences

    public init(preferences: MetadataPreferences = MetadataPreferences()) {
        self.preferences = preferences
    }

    public struct Ranked: Sendable {
        public let release: MBRelease
        public let score: Double
        /// 0...1; how confidently the top result can be auto-picked.
        public let confidence: Double
    }

    /// Returns candidates sorted best-first with an auto-pick confidence on
    /// the winner (high score + clear gap to the runner-up).
    public func rank(_ releases: [MBRelease], discID: String?, audioTrackCount: Int) -> [Ranked] {
        let scored = releases.map { (release: $0, score: score($0, discID: discID, audioTrackCount: audioTrackCount)) }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return [] }

        let maxScore = 10.0
        let runnerUp = scored.dropFirst().first?.score ?? 0
        let gap = (best.score - runnerUp) / maxScore
        let confidence = min(1, max(0, best.score / maxScore * 0.7 + gap * 0.3 + (scored.count == 1 ? 0.3 : 0)))

        return scored.enumerated().map { index, item in
            Ranked(release: item.release, score: item.score, confidence: index == 0 ? confidence : 0)
        }
    }

    private func score(_ release: MBRelease, discID: String?, audioTrackCount: Int) -> Double {
        var score = 0.0
        let media = release.media ?? []

        // Hard requirement in spirit: a medium must match our track count.
        let matchingMedium = media.contains { ($0.trackCount ?? $0.tracks?.count) == audioTrackCount }
        if matchingMedium { score += 3 } else { score -= 5 }

        // The exact DiscID attached to a medium is the strongest signal.
        if let discID, media.contains(where: { ($0.discs ?? []).contains { $0.id == discID } }) {
            score += 3
        }

        if media.contains(where: { ($0.format ?? "").localizedCaseInsensitiveContains("CD") }) {
            score += 1
        }
        if (release.status ?? "") == "Official" { score += 1 }
        if release.barcode?.isEmpty == false { score += 0.5 }
        if release.date?.isEmpty == false { score += 0.5 }

        if let country = release.country,
           let rank = preferences.preferredCountries.firstIndex(of: country) {
            score += 1.0 * (1.0 - Double(rank) / Double(max(preferences.preferredCountries.count, 1)))
        }

        return score
    }
}
