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
}
