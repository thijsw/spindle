import Foundation

public struct RipConfiguration: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Single pass, no error checking beyond what the drive corrects.
        case burst
        /// C2-guided (or compare-based) re-reading until passes agree.
        case secure(maxRetries: Int, agreeingPasses: Int)

        public static let secureDefault = Mode.secure(maxRetries: 16, agreeingPasses: 2)
    }

    public var mode: Mode
    /// Drive read offset correction in samples (positive = drive reads early).
    public var sampleOffset: Int
    /// Sectors per DKIOCCDREAD request.
    public var chunkSectors: Int
    /// Requested drive speed in KB/s (0xFFFF = max); nil leaves the drive alone.
    public var speedKBps: UInt16?

    public init(
        mode: Mode = .secureDefault,
        sampleOffset: Int = 0,
        chunkSectors: Int = 150,
        speedKBps: UInt16? = 0xFFFF
    ) {
        self.mode = mode
        self.sampleOffset = sampleOffset
        self.chunkSectors = chunkSectors
        self.speedKBps = speedKBps
    }
}

public struct RipProgress: Sendable {
    public let trackNumber: Int
    public let sectorsCompleted: Int
    public let totalSectors: Int
    public let rereads: Int

    public var fraction: Double {
        totalSectors > 0 ? Double(sectorsCompleted) / Double(totalSectors) : 0
    }
}

public struct RippedTrack: Sendable {
    public let trackNumber: Int
    public let wavURL: URL
    public let checksums: TrackChecksums
    /// Number of single-sector re-reads performed.
    public let rereads: Int
    /// Absolute LBAs that never produced agreeing reads (kept best-effort).
    public let unrecoverableSectors: [Int]
    public let usedC2: Bool
}

public enum RipError: Error, CustomStringConvertible, Sendable {
    case noAudioTracks
    case cancelled

    public var description: String {
        switch self {
        case .noAudioTracks: "The disc has no audio tracks"
        case .cancelled: "Rip was cancelled"
        }
    }
}
