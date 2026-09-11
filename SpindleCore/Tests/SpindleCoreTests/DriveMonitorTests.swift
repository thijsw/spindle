@testable import DiscDrive
import DiskArbitration
import Foundation
import Testing

@Suite struct DiskArbitrationDissentTests {
    /// Regression: DAReturn is a signed mach_error_t, so dissent codes arrive
    /// negative. Building the error used to force them through UInt32, which
    /// trapped and crashed the app on a dissented eject.
    @Test func mapsNegativeDissentCodesWithoutTrapping() throws {
        let codes = [
            kDAReturnError, kDAReturnBusy, kDAReturnBadArgument, kDAReturnExclusiveAccess,
            kDAReturnNoResources, kDAReturnNotFound, kDAReturnNotPermitted,
            kDAReturnNotPrivileged, kDAReturnNotReady, kDAReturnNotWritable, kDAReturnUnsupported,
        ]
        for code in codes {
            let status = DAReturn(code)
            #expect(status < 0, "dissent codes are negative as DAReturn")
            let error = try #require(dissentError(operation: .eject, status: status, reason: "nope"))
            #expect(error.status == status)
            #expect(error.operation == "eject")
            #expect(error.description.contains("f8da"))
            #expect(error.description.contains("nope"))
        }
    }

    @Test func unmountOfAnUnmountedDiscSucceeds() {
        #expect(dissentError(operation: .unmount,
                             status: DAReturn(kDAReturnNotMounted), reason: nil) == nil)
        // The same code on an eject is still a genuine failure.
        #expect(dissentError(operation: .eject,
                             status: DAReturn(kDAReturnNotMounted), reason: nil) != nil)
    }
}
