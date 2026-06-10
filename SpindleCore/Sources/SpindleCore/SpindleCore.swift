/// Umbrella module for the Spindle pipeline. Grows with each milestone:
/// the pipeline coordinator, disc job model, and persistence live here.
public enum Spindle {
    public static let version = "0.1.0"
    /// MusicBrainz requires a meaningful User-Agent with contact information.
    public static let userAgent = "Spindle/\(version) ( thijs@wijnmaalen.name )"
}
