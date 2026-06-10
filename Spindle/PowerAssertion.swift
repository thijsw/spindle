import Foundation
import IOKit.pwr_mgt

/// Prevents idle sleep while discs are being processed.
@MainActor
final class PowerAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func activate() {
        guard !isActive else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Spindle is ripping a CD" as CFString,
            &assertionID
        )
        isActive = result == kIOReturnSuccess
    }

    func release() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        isActive = false
    }
}
