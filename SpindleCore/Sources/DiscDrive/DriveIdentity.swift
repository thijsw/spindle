import Foundation

/// Vendor/product identity of an optical drive, used to suggest a read offset.
public struct DriveIdentity: Sendable, Hashable, Codable {
    public let vendor: String
    public let product: String
    public let revision: String
    /// The actual mechanism, when it differs from the marketing identity —
    /// e.g. an "Apple SuperDrive" whose media node reveals an LG
    /// "HL-DT-ST DVDRW GX50N" inside. Read offsets follow the mechanism.
    public let mechanism: String?

    public init(vendor: String, product: String, revision: String, mechanism: String? = nil) {
        self.vendor = vendor
        self.product = product
        self.revision = revision
        self.mechanism = mechanism
    }

    public var displayName: String {
        let marketing = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        if let mechanism, !mechanism.localizedCaseInsensitiveContains(product) {
            return "\(marketing) (\(mechanism))"
        }
        return marketing
    }

    /// Stable key for the per-drive offset preference.
    public var offsetKey: String {
        mechanism ?? [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Suggests a CD read sample offset for known drive families.
///
/// These are family-level heuristics derived from commonly reported
/// AccurateRip offsets — most models within a family share one value.
/// A suggestion is exactly that: the UI labels it unverified until the user
/// confirms it (or a CTDB match corroborates the rip).
public enum DriveOffsetTable {
    public struct Suggestion: Sendable, Equatable {
        public let samples: Int
        public let confidence: Confidence
        public enum Confidence: Sendable, Equatable {
            /// Typical value for the drive family; verify before trusting.
            case vendorTypical
        }
    }

    private static let familyTypicalOffsets: [String: Int] = [
        "MATSHITA": 102, // Panasonic
        "HL-DT-ST": 6, // LG (incl. mechanisms inside Apple SuperDrives)
        "TSSTCORP": 6, // Toshiba Samsung
        "PLEXTOR": 30,
        "PIONEER": 667,
        "LITE-ON": 6,
        "ASUS": 6,
        "OPTIARC": 48, // Sony Optiarc
        "SONY": 48,
    ]

    public static func suggestion(for identity: DriveIdentity) -> Suggestion? {
        // The mechanism string (when known) beats the marketing vendor:
        // "Apple SuperDrive" says nothing about the offset, the LG or
        // Panasonic mechanism inside does.
        let haystacks = [identity.mechanism ?? "", identity.vendor, identity.product]
            .map { $0.uppercased() }
        for haystack in haystacks where !haystack.isEmpty {
            for (family, offset) in familyTypicalOffsets where haystack.contains(family) {
                return Suggestion(samples: offset, confidence: .vendorTypical)
            }
        }
        return nil
    }
}
