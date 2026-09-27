import DiscDrive
import Foundation

/// Device reads that survive unreadable sectors.
///
/// The cost model: a read that *fails* costs the drive's entire internal
/// retry storm (1–2 minutes on some drives), so the budget is failing
/// contacts, not sectors. Healthy spans are read with exponentially growing
/// requests; damage is crossed by zero-filling exponentially growing blocks
/// at one failing probe each, with the final block retro-bisected so run
/// boundaries stay sector-exact. Confirmed runs are remembered in the shared
/// `DamageMap` and never touched again (pass 2, settles, re-rips).
///
/// Damaged media reads markedly better slowly (the XLD/dbpoweramp
/// playbook), so the first struggle drops the drive to a low speed for the
/// rest of the track.
struct ResilientReader: Sendable {
    let device: any CDDeviceIO
    /// Readable sector bounds of the audio area (0 ..< lead-out LBA).
    let readableSectors: Range<Int>
    /// Largest request the drive accepts, in sectors.
    let maxRequestSectors: Int
    let damage: DamageMap

    /// Conservative bound on drive read-cache coverage, in sectors
    /// (cdparanoia's default cache model: 1200 sectors ≈ 2.8 MB ≈ 16 s).
    private static let cacheFlushDistance = 1200
    /// A read slower than this means the drive is struggling internally;
    /// host-side retries add nothing beyond this point.
    static let struggleThreshold: Duration = .seconds(2)
    /// Speed requested while inside a damaged region (≈ 4×).
    private static let damagedRegionSpeed: UInt16 = 706

    /// Reads `sectors`, zero-filling what the drive cannot deliver, and
    /// reports the absolute LBAs that were given up on.
    func read(
        _ sectors: Range<Int>, areas: SectorAreas, health: RipHealth
    ) async throws -> (data: Data, unrecoverable: [Int]) {
        let knownBad = await damage.knownBadRuns(intersecting: sectors)

        // A charted run ending exactly at our start means the scratch
        // continues into this request: skip the doomed whole-range attempts
        // and resume crossing it with large blocks immediately.
        if sectors.lowerBound > readableSectors.lowerBound {
            let touching = await damage.knownBadRuns(
                intersecting: (sectors.lowerBound - 1) ..< sectors.lowerBound
            )
            if touching.contains(where: { $0.upperBound == sectors.lowerBound }) {
                return try await mapDamage(
                    sectors, areas: areas, health: health, knownBad: knownBad, continuingRun: true
                )
            }
        }

        // Fast path: no known damage inside — try the whole range.
        if knownBad.isEmpty {
            let started = ContinuousClock.now
            if let buffer = try? await device.readSectors(sectors, areas: areas) {
                // Success, but slower than the drive's own retry storm
                // allows: drop to low speed for the rest of the track.
                if ContinuousClock.now - started > Self.struggleThreshold {
                    await slowDownOnce(health)
                }
                return (buffer.data, [])
            }
            if await slowDownOnce(health) {
                // One retry of the whole range at low speed.
                if let buffer = try? await device.readSectors(sectors, areas: areas) {
                    return (buffer.data, [])
                }
            }
        }

        return try await mapDamage(sectors, areas: areas, health: health, knownBad: knownBad)
    }

    /// Drops the drive to the damaged-region speed the first time a track
    /// struggles. Returns true when this call did the slowing.
    @discardableResult
    func slowDownOnce(_ health: RipHealth) async -> Bool {
        guard await health.noteStruggle() else { return false }
        try? await device.setSpeed(Self.damagedRegionSpeed)
        return true
    }

    /// Evicts the drive's read cache with a *small* backseek — just beyond
    /// the modeled cache window. Same flush effect as a cross-disc jump on
    /// read-ahead caches, a fraction of the head travel.
    func flushCache(near lba: Int) async {
        let area = readableSectors
        guard area.count > 1 else { return }
        var target = lba - Self.cacheFlushDistance
        if target < area.lowerBound {
            target = min(lba + Self.cacheFlushDistance, area.upperBound - 1)
        }
        _ = try? await device.readSectors(target ..< target + 1, areas: .user)
    }

    // MARK: Damage mapping

    private func mapDamage(
        _ sectors: Range<Int>,
        areas: SectorAreas,
        health: RipHealth,
        knownBad: [Range<Int>],
        continuingRun: Bool = false
    ) async throws -> (data: Data, unrecoverable: [Int]) {
        let stride = areas.bytesPerSector
        var out = Data(count: sectors.count * stride) // zero-filled canvas
        var bad = Set<Int>()

        func fill(_ buffer: SectorBuffer, at lba: Int) {
            let dest = (lba - sectors.lowerBound) * stride
            out.replaceSubrange(dest ..< dest + buffer.data.count, with: buffer.data)
        }

        var cursor = sectors.lowerBound
        // knownBad is sorted; this index tracks the next run ahead of the cursor.
        var nextBadIndex = 0
        var goodStep = 8
        var consecutiveGoodSingles = 0

        // When continuing a charted scratch, cross it one large block per
        // failing probe instead of rediscovering it chunk by chunk.
        if continuingRun {
            cursor = try await crossBadRun(
                from: cursor, in: sectors, areas: areas,
                initialBlock: 64, blockCap: 256,
                health: health, out: &out, bad: &bad
            )
        }

        while cursor < sectors.upperBound {
            try Task.checkCancellation()
            try await health.checkDeadline()
            while nextBadIndex < knownBad.count, knownBad[nextBadIndex].upperBound <= cursor {
                nextBadIndex += 1
            }
            // Confirmed damage: zero-fill without touching the device.
            if nextBadIndex < knownBad.count, knownBad[nextBadIndex].contains(cursor) {
                let span = cursor ..< min(knownBad[nextBadIndex].upperBound, sectors.upperBound)
                bad.formUnion(span)
                cursor = span.upperBound
                continue
            }
            let nextKnownBad = nextBadIndex < knownBad.count
                ? knownBad[nextBadIndex].lowerBound
                : sectors.upperBound

            let n = min(goodStep, nextKnownBad - cursor, sectors.upperBound - cursor)
            if let buffer = try? await device.readSectors(cursor ..< cursor + n, areas: areas) {
                fill(buffer, at: cursor)
                cursor += n
                if goodStep == 1 {
                    consecutiveGoodSingles += 1
                    if consecutiveGoodSingles >= 16 { goodStep = 8 }
                } else {
                    goodStep = min(goodStep * 2, maxRequestSectors)
                }
                continue
            }

            if n > 1 {
                // Damage somewhere in the block: single-step to find it
                // (successes are cheap; only the actual hit is expensive).
                goodStep = 1
                consecutiveGoodSingles = 0
                continue
            }

            // cursor is confirmed unreadable: cross the run with exponential
            // zero-blocks, one failing probe per block.
            cursor = try await crossBadRun(
                from: cursor, in: sectors, areas: areas,
                initialBlock: 1, blockCap: 32,
                health: health, out: &out, bad: &bad
            )
            goodStep = 1
            consecutiveGoodSingles = 0
        }

        return (out, bad.sorted())
    }

    /// Crosses a bad run starting at `from`: zero-fills exponentially
    /// growing blocks at one failing probe each, retro-bisecting the final
    /// block for a sector-exact boundary. Returns the new cursor.
    private func crossBadRun(
        from: Int,
        in sectors: Range<Int>,
        areas: SectorAreas,
        initialBlock: Int,
        blockCap: Int,
        health: RipHealth,
        out: inout Data,
        bad: inout Set<Int>
    ) async throws -> Int {
        let stride = areas.bytesPerSector
        var cursor = from
        var zeroBlock = initialBlock
        while cursor < sectors.upperBound {
            try Task.checkCancellation()
            try await health.checkDeadline()
            let lastBlock = cursor ..< min(cursor + zeroBlock, sectors.upperBound)
            bad.formUnion(lastBlock)
            cursor = lastBlock.upperBound
            guard cursor < sectors.upperBound else { break }

            if let probe = try? await device.readSectors(cursor ..< cursor + 1, areas: areas) {
                let probeDest = (cursor - sectors.lowerBound) * stride
                out.replaceSubrange(probeDest ..< probeDest + probe.data.count, with: probe.data)
                cursor += 1
                // The run ended inside the last zero block: recover its
                // readable tail so the boundary is sector-exact.
                if let recovered = await recoverTail(of: lastBlock, areas: areas) {
                    let dest = (recovered.from - sectors.lowerBound) * stride
                    out.replaceSubrange(dest ..< dest + recovered.buffer.data.count, with: recovered.buffer.data)
                    bad.subtract(recovered.from ..< lastBlock.upperBound)
                    await damage.recordBadRun(from ..< recovered.from)
                } else {
                    await damage.recordBadRun(from ..< lastBlock.upperBound)
                }
                return cursor
            }
            zeroBlock = min(zeroBlock * 2, blockCap)
        }
        // Run reaches the end of this request; it may continue into the
        // next chunk (continuation mode picks it up there).
        await damage.recordBadRun(from ..< sectors.upperBound)
        return cursor
    }

    /// Binary-searches the readable tail of a zero-filled block: the
    /// smallest position whose suffix reads cleanly. Costs ≤ log₂(block)
    /// contacts, only some of which fail.
    private func recoverTail(
        of block: Range<Int>, areas: SectorAreas
    ) async -> (from: Int, buffer: SectorBuffer)? {
        var low = block.lowerBound
        var high = block.upperBound
        while low < high {
            let mid = (low + high) / 2
            if (try? await device.readSectors(mid ..< block.upperBound, areas: areas)) != nil {
                high = mid
            } else {
                low = mid + 1
            }
        }
        guard high < block.upperBound,
              let buffer = try? await device.readSectors(high ..< block.upperBound, areas: areas)
        else { return nil }
        return (high, buffer)
    }
}
