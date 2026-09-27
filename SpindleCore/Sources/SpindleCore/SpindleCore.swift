import Foundation

/// Umbrella module for the Spindle pipeline: the coordinator, the disc job
/// model and persistence live here.
public enum Spindle {
    /// Marketing version from the running bundle (stamped from the git tag at
    /// release time); "dev" for `swift run` and test binaries.
    public static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// MusicBrainz requires a meaningful User-Agent with contact information.
    public static var userAgent: String { "Spindle/\(version) ( thijs@wijnmaalen.name )" }
}
