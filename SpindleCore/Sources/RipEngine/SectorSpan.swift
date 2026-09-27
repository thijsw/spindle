import DiscDrive
import Foundation

/// The device sectors that cover a window of the virtual, offset-corrected
/// disc byte stream. With a read offset the window straddles sector
/// boundaries and, at the disc edges, extends past the readable area; the
/// span knows which sectors to read and how to cut the result back down.
struct SectorSpan {
    private static let bytesPerSector = SectorAreas.audioBytesPerSector

    /// Window in the corrected byte stream.
    let byteRange: Range<Int>
    /// Every sector the window touches, readable or not.
    let sectors: Range<Int>
    /// The part of `sectors` the drive can actually deliver.
    let readable: Range<Int>

    init(covering byteRange: Range<Int>, readableSectors: Range<Int>) {
        let bps = Self.bytesPerSector
        let first = byteRange.lowerBound.flooredDivision(by: bps)
        let last = (byteRange.upperBound + bps - 1).flooredDivision(by: bps)
        self.byteRange = byteRange
        self.sectors = first ..< last
        self.readable = sectors.clamped(to: readableSectors)
    }

    /// Cuts the window out of the audio read for `readable`, zero-filling
    /// the sectors outside the readable area. Returns a slice (no copy)
    /// when every touched sector was readable — the common case.
    func window(fromReadableAudio audio: Data) -> Data {
        let bps = Self.bytesPerSector
        let start = byteRange.lowerBound - sectors.lowerBound * bps
        if readable == sectors {
            return audio[audio.startIndex + start ..< audio.startIndex + start + byteRange.count]
        }
        var canvas = Data(count: sectors.count * bps)
        if !readable.isEmpty {
            let dest = (readable.lowerBound - sectors.lowerBound) * bps
            canvas.replaceSubrange(dest ..< dest + audio.count, with: audio)
        }
        return canvas.subdata(in: start ..< start + byteRange.count)
    }
}

extension Int {
    /// Floored division (rounds toward negative infinity), needed because
    /// negative-offset byte positions must map to the preceding sector.
    func flooredDivision(by divisor: Int) -> Int {
        let q = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? q - 1 : q
    }
}
