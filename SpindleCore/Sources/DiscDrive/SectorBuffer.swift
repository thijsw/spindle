import Foundation

/// Which per-sector areas to request from DKIOCCDREAD. The kernel returns the
/// requested areas concatenated per sector: user data (2352 B), then C2 error
/// flags (294 B), then Q subchannel (16 B).
public struct SectorAreas: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// 2352 bytes of CDDA audio.
    public static let user = SectorAreas(rawValue: 0x10)
    /// 294 bytes of C2 error pointer bits (one bit per audio byte).
    public static let errorFlags = SectorAreas(rawValue: 0x02)
    /// 16 bytes of Q subchannel data.
    public static let subChannelQ = SectorAreas(rawValue: 0x04)

    public static let audioBytesPerSector = 2352
    public static let c2BytesPerSector = 294
    public static let subQBytesPerSector = 16

    public var bytesPerSector: Int {
        var n = 0
        if contains(.user) { n += Self.audioBytesPerSector }
        if contains(.errorFlags) { n += Self.c2BytesPerSector }
        if contains(.subChannelQ) { n += Self.subQBytesPerSector }
        return n
    }
}

/// Raw result of reading a contiguous range of CDDA sectors.
public struct SectorBuffer: Sendable {
    public let startLBA: Int
    public let sectorCount: Int
    public let areas: SectorAreas
    public let data: Data

    public init(startLBA: Int, sectorCount: Int, areas: SectorAreas, data: Data) {
        self.startLBA = startLBA
        self.sectorCount = sectorCount
        self.areas = areas
        self.data = data
    }

    private func slice(of sectorIndex: Int, areaOffset: Int, length: Int) -> Data {
        let base = sectorIndex * areas.bytesPerSector + areaOffset
        return data.subdata(in: data.startIndex + base ..< data.startIndex + base + length)
    }

    /// 2352 bytes of audio for the given sector index within this buffer.
    public func audio(sector: Int) -> Data {
        precondition(areas.contains(.user))
        return slice(of: sector, areaOffset: 0, length: SectorAreas.audioBytesPerSector)
    }

    /// C2 error bits for the given sector, or nil if not requested.
    public func c2Flags(sector: Int) -> Data? {
        guard areas.contains(.errorFlags) else { return nil }
        let offset = areas.contains(.user) ? SectorAreas.audioBytesPerSector : 0
        return slice(of: sector, areaOffset: offset, length: SectorAreas.c2BytesPerSector)
    }

    /// Q subchannel bytes for the given sector, or nil if not requested.
    public func subQ(sector: Int) -> Data? {
        guard areas.contains(.subChannelQ) else { return nil }
        var offset = 0
        if areas.contains(.user) { offset += SectorAreas.audioBytesPerSector }
        if areas.contains(.errorFlags) { offset += SectorAreas.c2BytesPerSector }
        return slice(of: sector, areaOffset: offset, length: SectorAreas.subQBytesPerSector)
    }

    /// True if any C2 bit is set for the given sector (i.e. the drive flagged
    /// at least one uncorrected byte).
    public func hasC2Error(sector: Int) -> Bool {
        guard let flags = c2Flags(sector: sector) else { return false }
        return flags.contains { $0 != 0 }
    }

    /// All audio bytes of the buffer concatenated (2352 × sectorCount).
    public func allAudio() -> Data {
        guard areas != .user else { return data }
        var out = Data(capacity: sectorCount * SectorAreas.audioBytesPerSector)
        for s in 0 ..< sectorCount { out.append(audio(sector: s)) }
        return out
    }
}
