import Encoding
import Foundation
import Metadata
import Naming
import RipEngine
import Transfer

/// All user-configurable behavior. Persisted as JSON in Application Support;
/// secrets live in the Keychain.
public struct Preferences: Sendable, Codable, Equatable {
    public enum EjectTiming: String, Sendable, Codable, CaseIterable {
        /// Eject as soon as audio is staged and checksummed (default —
        /// the user can insert the next disc while processing continues).
        case afterRip
        /// Eject only when encoding and transfer have finished.
        case afterEverything
    }

    public enum RipMode: String, Sendable, Codable, CaseIterable {
        case secure
        case fast
    }

    /// What happens when MusicBrainz has no match for a disc.
    public enum UnmatchedDiscPolicy: String, Sendable, Codable, CaseIterable {
        /// Pause before encoding and ask for hand-edited tags (the rip and
        /// eject still proceed, so the batch keeps moving).
        case askForTags
        /// Tag from CD-TEXT or as "Unknown Album" and continue unattended.
        case tagAsUnknown
    }

    public var format: AudioFormat
    public var namingTemplate: NamingTemplate
    public var destination: DestinationConfig?
    public var ejectTiming: EjectTiming
    public var ripMode: RipMode
    public var maxRetries: Int
    /// Read-offset correction in samples, keyed by "vendor product" string.
    public var driveOffsets: [String: Int]
    /// Drives whose C2 error reporting was caught lying (same keys as
    /// `driveOffsets`).
    public var drivesWithUnreliableC2: [String]
    public var metadata: MetadataPreferences
    public var autoPickRelease: Bool
    public var unmatchedDiscPolicy: UnmatchedDiscPolicy
    public var coverArtSize: CoverArtSize
    public var writeCoverJPEG: Bool
    /// Write an archival rip log next to the audio in each album folder.
    public var writeRipLog: Bool
    /// Write a per-track-file cue sheet next to the audio.
    public var writeCueSheet: Bool
    public var notificationsEnabled: Bool
    public var showMenuBarExtra: Bool

    public init(
        format: AudioFormat = .flac,
        namingTemplate: NamingTemplate = .standard,
        destination: DestinationConfig? = nil,
        ejectTiming: EjectTiming = .afterRip,
        ripMode: RipMode = .secure,
        maxRetries: Int = 16,
        driveOffsets: [String: Int] = [:],
        drivesWithUnreliableC2: [String] = [],
        metadata: MetadataPreferences = MetadataPreferences(),
        autoPickRelease: Bool = true,
        unmatchedDiscPolicy: UnmatchedDiscPolicy = .askForTags,
        coverArtSize: CoverArtSize = .large,
        writeCoverJPEG: Bool = true,
        writeRipLog: Bool = true,
        writeCueSheet: Bool = true,
        notificationsEnabled: Bool = true,
        showMenuBarExtra: Bool = false
    ) {
        self.format = format
        self.namingTemplate = namingTemplate
        self.destination = destination
        self.ejectTiming = ejectTiming
        self.ripMode = ripMode
        self.maxRetries = maxRetries
        self.driveOffsets = driveOffsets
        self.drivesWithUnreliableC2 = drivesWithUnreliableC2
        self.metadata = metadata
        self.autoPickRelease = autoPickRelease
        self.unmatchedDiscPolicy = unmatchedDiscPolicy
        self.coverArtSize = coverArtSize
        self.writeCoverJPEG = writeCoverJPEG
        self.writeRipLog = writeRipLog
        self.writeCueSheet = writeCueSheet
        self.notificationsEnabled = notificationsEnabled
        self.showMenuBarExtra = showMenuBarExtra
    }

    public func ripConfiguration(forDrive identity: String?) -> RipConfiguration {
        RipConfiguration(
            mode: ripMode == .secure
                ? .secure(maxRetries: maxRetries, agreeingPasses: 2)
                : .burst,
            sampleOffset: identity.flatMap { driveOffsets[$0] } ?? 0,
            allowC2: identity.map { !drivesWithUnreliableC2.contains($0) } ?? true
        )
    }

    public mutating func markC2Unreliable(forDrive identity: String) {
        guard !drivesWithUnreliableC2.contains(identity) else { return }
        drivesWithUnreliableC2.append(identity)
    }
}

public enum PreferencesStore {
    public static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spindle")
    }

    static var fileURL: URL {
        applicationSupportURL.appendingPathComponent("preferences.json")
    }

    public static func load() -> Preferences {
        guard let data = try? Data(contentsOf: fileURL),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return prefs
    }

    public static func save(_ preferences: Preferences) {
        try? FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(preferences))?.write(to: fileURL)
    }
}
