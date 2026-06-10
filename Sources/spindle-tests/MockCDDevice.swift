import DiscDrive
import Foundation

/// In-memory CD device for testing the rip engine. Audio content is a
/// deterministic function of the absolute byte position, so any slice of the
/// disc can be predicted independently. Sectors can be made flaky (different
/// garbage on the first N reads) with or without C2 flagging.
actor MockCDDevice: CDDeviceIO {
    let bsdName = "mockdisk"

    struct FlakySector {
        var badReads: Int // number of reads that return garbage before settling
        var flagsC2: Bool // whether the garbage reads carry C2 error bits
    }

    let leadOut: Int
    var supportsC2: Bool
    private var flaky: [Int: FlakySector]
    private(set) var readCount = 0
    private var garbageSeed = 0

    init(leadOut: Int, supportsC2: Bool = true, flaky: [Int: FlakySector] = [:]) {
        self.leadOut = leadOut
        self.supportsC2 = supportsC2
        self.flaky = flaky
    }

    /// The canonical audio byte at an absolute disc byte position.
    static func canonicalByte(at position: Int) -> UInt8 {
        // Cheap deterministic mix with no long-period repeats at sector size.
        var x = UInt64(position) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29
        return UInt8(truncatingIfNeeded: x)
    }

    static func canonicalAudio(sector lba: Int) -> Data {
        let base = lba * 2352
        return Data((0 ..< 2352).map { canonicalByte(at: base + $0) })
    }

    func readSectors(_ range: Range<Int>, areas: SectorAreas) throws -> SectorBuffer {
        if areas.contains(.errorFlags), !supportsC2 {
            throw DiscDriveError.ioctlFailed(name: "DKIOCCDREAD", code: 22) // EINVAL
        }
        guard range.lowerBound >= 0, range.upperBound <= leadOut else {
            throw DiscDriveError.ioctlFailed(name: "DKIOCCDREAD", code: 5) // EIO
        }
        readCount += 1

        var data = Data(capacity: range.count * areas.bytesPerSector)
        for lba in range {
            var audio = Self.canonicalAudio(sector: lba)
            var c2Flagged = false

            if var state = flaky[lba], state.badReads > 0 {
                garbageSeed += 1
                let seed = garbageSeed
                audio = Data((0 ..< 2352).map {
                    MockCDDevice.canonicalByte(at: lba * 2352 + $0) ^ UInt8(truncatingIfNeeded: seed &+ $0 / 911 &+ 1)
                })
                c2Flagged = state.flagsC2
                state.badReads -= 1
                flaky[lba] = state
            }

            if areas.contains(.user) { data.append(audio) }
            if areas.contains(.errorFlags) {
                var flags = Data(count: SectorAreas.c2BytesPerSector)
                if c2Flagged { flags[0] = 0x80 }
                data.append(flags)
            }
            if areas.contains(.subChannelQ) {
                data.append(Data(count: SectorAreas.subQBytesPerSector))
            }
        }
        return SectorBuffer(startLBA: range.lowerBound, sectorCount: range.count, areas: areas, data: data)
    }

    func readFullTOC() throws -> Data { Data() }
    func readCDTextPacks() throws -> Data? { nil }
    func readISRC(track: Int) throws -> String? { nil }
    func readMCN() throws -> String? { nil }
    func setSpeed(_ kbps: UInt16) throws {}
}
