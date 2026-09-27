import Foundation
import Metadata

/// MusicBrainz candidates for a disc, ranked: the pipeline's identify stage
/// and the CLI share it so they rank the same way.
public struct ReleaseLookup: Sendable {
    public let ranked: [ReleaseScorer.Ranked]
    /// The releases are attached to the disc's own DiscID (not a fuzzy TOC
    /// search), which makes a lone result authoritative.
    public let exactDiscID: Bool

    public static func perform(
        disc: DiscTOC,
        audioTrackCount: Int,
        metadata: any MetadataProviding,
        preferences: MetadataPreferences
    ) async throws -> ReleaseLookup {
        let releases: [MBRelease]
        var exactDiscID = false
        switch try await metadata.lookup(disc: disc) {
        case .matched(let found):
            releases = found
            exactDiscID = true
        case .fuzzy(let found):
            releases = found
        case .none:
            releases = []
        }
        let ranked = ReleaseScorer(preferences: preferences).rank(
            releases, discID: disc.musicBrainzDiscID, audioTrackCount: audioTrackCount
        )
        return ReleaseLookup(ranked: ranked, exactDiscID: exactDiscID)
    }
}
