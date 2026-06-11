import CIOCD
import Foundation

/// Talks to a physical CD drive through the raw disk node (`/dev/rdiskN`) and
/// the IOCDMedia BSD client ioctls. Actor isolation serializes device access.
public actor CDDrive: CDDeviceIO {
    public let bsdName: String
    private var fd: Int32

    public init(bsdName: String) throws {
        let path = "/dev/r\(bsdName)"
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw DiscDriveError.openFailed(path: path, code: errno)
        }
        self.bsdName = bsdName
        self.fd = fd
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Releases the raw device handle. Must be called before ejecting — an
    /// open `/dev/rdiskN` makes the device busy and `DADiskEject` fails.
    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Set SPINDLE_TRACE_IO=1 to log every device read slower than 500 ms.
    private static let traceIO = ProcessInfo.processInfo.environment["SPINDLE_TRACE_IO"] != nil

    public func readSectors(_ range: Range<Int>, areas: SectorAreas) throws -> SectorBuffer {
        precondition(!range.isEmpty)
        precondition(areas.contains(.user) || areas.contains(.errorFlags) || areas.contains(.subChannelQ))
        let traceStart = Self.traceIO ? ContinuousClock.now : nil
        defer {
            if let traceStart {
                let elapsed = ContinuousClock.now - traceStart
                if elapsed > .milliseconds(500) {
                    FileHandle.standardError.write(Data(
                        "[trace] read \(range.lowerBound)..<\(range.upperBound) areas=\(areas.rawValue) took \(elapsed)\n".utf8
                    ))
                }
            }
        }

        let length = range.count * areas.bytesPerSector
        var buffer = Data(count: length)
        let code = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
            var req = dk_cd_read_t()
            // For CDDA, offset addresses the media in 2352-byte sectors
            // regardless of which areas are requested.
            req.offset = UInt64(range.lowerBound) * UInt64(SectorAreas.audioBytesPerSector)
            req.sectorArea = areas.rawValue
            req.sectorType = UInt8(kCDSectorTypeCDDA.rawValue)
            req.bufferLength = UInt32(length)
            req.buffer = raw.baseAddress
            return ciocd_read(fd, &req)
        }
        guard code == 0 else {
            throw DiscDriveError.ioctlFailed(name: "DKIOCCDREAD(lba \(range.lowerBound)..<\(range.upperBound))", code: code)
        }
        return SectorBuffer(startLBA: range.lowerBound, sectorCount: range.count, areas: areas, data: buffer)
    }

    public func readFullTOC() throws -> Data {
        try readTOC(format: 2)
    }

    public func readCDTextPacks() throws -> Data? {
        do {
            let data = try readTOC(format: 5)
            // A 4-byte header with no packs means no CD-TEXT.
            return data.count > 4 ? data : nil
        } catch DiscDriveError.ioctlFailed {
            return nil // drives report an error when the disc has no CD-TEXT
        }
    }

    private func readTOC(format: UInt8) throws -> Data {
        let capacity = 4096
        var buffer = Data(count: capacity)
        var actualLength: UInt16 = 0
        let code = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int32 in
            var req = dk_cd_read_toc_t()
            req.format = format
            req.formatAsTime = 1 // MSF addressing; TOC.parse expects it
            req.address.session = 0
            req.bufferLength = UInt16(capacity)
            req.buffer = raw.baseAddress
            let rc = ciocd_read_toc(fd, &req)
            actualLength = req.bufferLength
            return rc
        }
        guard code == 0 else {
            throw DiscDriveError.ioctlFailed(name: "DKIOCCDREADTOC(format \(format))", code: code)
        }
        return buffer.prefix(Int(actualLength))
    }

    public func readISRC(track: Int) throws -> String? {
        var req = dk_cd_read_isrc_t()
        req.track = UInt8(track)
        let code = ciocd_read_isrc(fd, &req)
        guard code == 0 else { return nil } // not encoded or not supported
        let isrc = withUnsafeBytes(of: req.isrc) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let trimmed = isrc.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 12 ? trimmed : nil
    }

    public func readMCN() throws -> String? {
        var req = dk_cd_read_mcn_t()
        let code = ciocd_read_mcn(fd, &req)
        guard code == 0 else { return nil }
        let mcn = withUnsafeBytes(of: req.mcn) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let trimmed = mcn.trimmingCharacters(in: .whitespaces)
        // An all-zero MCN means "not present".
        return trimmed.isEmpty || trimmed.allSatisfy({ $0 == "0" }) ? nil : trimmed
    }

    public func setSpeed(_ kbps: UInt16) throws {
        let code = ciocd_set_speed(fd, kbps)
        guard code == 0 else {
            throw DiscDriveError.ioctlFailed(name: "DKIOCCDSETSPEED", code: code)
        }
    }
}
