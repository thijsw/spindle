import Encoding
import Foundation
import Testing

@testable import SpindleCore

@Suite struct PreferencesTests {
    @Test func roundTrips() throws {
        var prefs = Preferences(format: .alac)
        prefs.driveOffsets = ["HL-DT-ST GX50N": 6]
        prefs.drivesWithUnreliableC2 = ["HL-DT-ST GX50N"]
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded == prefs)
    }

    /// A preferences file written by an older version lacks newer keys. That
    /// must not fail the decode — a failed decode falls back to defaults and
    /// silently wipes the destination, drive offsets and C2 verdicts.
    @Test func missingKeysKeepTheirDefaultsWithoutLosingTheRest() throws {
        var prefs = Preferences(format: .aac)
        prefs.destination = .localFolder(path: "/Volumes/Music")
        prefs.driveOffsets = ["HL-DT-ST GX50N": 6]
        prefs.writeCueSheet = false

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs)) as! [String: Any]
        json.removeValue(forKey: "writeCueSheet")
        json.removeValue(forKey: "unmatchedDiscPolicy")
        json.removeValue(forKey: "notificationsEnabled")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.destination == .localFolder(path: "/Volumes/Music"))
        #expect(decoded.driveOffsets == ["HL-DT-ST GX50N": 6])
        #expect(decoded.format == .aac)
        #expect(decoded.writeCueSheet == Preferences().writeCueSheet, "missing key → default")
        #expect(decoded.unmatchedDiscPolicy == Preferences().unmatchedDiscPolicy)
    }
}
