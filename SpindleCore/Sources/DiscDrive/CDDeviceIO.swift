import Foundation

/// Abstraction over a CD device. `CDDrive` is the real implementation; tests
/// use mocks that replay captured sector dumps and inject errors.
public protocol CDDeviceIO: Actor {
    var bsdName: String { get }

    /// Reads a contiguous range of CDDA sectors (0-based LBA).
    func readSectors(_ range: Range<Int>, areas: SectorAreas) throws -> SectorBuffer

    /// Raw DKIOCCDREADTOC format-2 (full TOC) response.
    func readFullTOC() throws -> Data

    /// Raw CD-TEXT packs (DKIOCCDREADTOC format 5), or nil if the disc has none.
    func readCDTextPacks() throws -> Data?

    /// 12-character ISRC for a track, or nil if not encoded on the disc.
    func readISRC(track: Int) throws -> String?

    /// Media catalog number (UPC/EAN), or nil if not encoded.
    func readMCN() throws -> String?

    /// Requests a read speed in KB/s (0xFFFF = maximum). Drives may ignore it.
    func setSpeed(_ kbps: UInt16) throws

    /// Releases the underlying device handle so the disc can be ejected.
    func close()
}

public extension CDDeviceIO {
    func close() {} // mocks have nothing to release
}

public enum DiscDriveError: Error, CustomStringConvertible, Sendable {
    case openFailed(path: String, code: Int32)
    case ioctlFailed(name: String, code: Int32)
    case shortRead(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .openFailed(let path, let code):
            "Could not open \(path): \(String(cString: strerror(code))) (errno \(code))"
        case .ioctlFailed(let name, let code):
            "\(name) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .shortRead(let expected, let got):
            "Short read: expected \(expected) bytes, got \(got)"
        }
    }
}
