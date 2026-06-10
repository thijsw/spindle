import Foundation

/// Vendor/product identity of an optical drive, used to suggest a read offset.
public struct DriveIdentity: Sendable, Hashable, Codable {
    public let vendor: String
    public let product: String
    public let revision: String

    public init(vendor: String, product: String, revision: String) {
        self.vendor = vendor
        self.product = product
        self.revision = revision
    }

    public var displayName: String {
        [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Suggests a CD read sample offset for known drive families.
///
/// These are vendor-level heuristics derived from commonly reported
/// AccurateRip offsets — most models within a vendor family share one value.
/// A suggestion is exactly that: the UI labels it unverified until the user
/// confirms it (or a CTDB match corroborates the rip).
public enum DriveOffsetTable {
    public struct Suggestion: Sendable, Equatable {
        public let samples: Int
        public let confidence: Confidence
        public enum Confidence: Sendable, Equatable {
            /// Typical value for the vendor family; verify before trusting.
            case vendorTypical
        }
    }

    private static let vendorTypicalOffsets: [String: Int] = [
        "MATSHITA": 102, // Panasonic — includes Apple SuperDrives
        "HL-DT-ST": 6, // LG
        "TSSTCORP": 6, // Toshiba Samsung
        "PLEXTOR": 30,
        "PIONEER": 667,
        "LITE-ON": 6,
        "ASUS": 6,
        "OPTIARC": 48, // Sony Optiarc
        "SONY": 48,
    ]

    public static func suggestion(for identity: DriveIdentity) -> Suggestion? {
        let vendor = identity.vendor.uppercased()
        for (key, offset) in vendorTypicalOffsets where vendor.contains(key) {
            return Suggestion(samples: offset, confidence: .vendorTypical)
        }
        return nil
    }
}
