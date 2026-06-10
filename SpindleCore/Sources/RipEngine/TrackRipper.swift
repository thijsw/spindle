import DiscDrive
import Foundation

/// Rips one track: reads sectors (securely if configured), applies sample
/// offset correction with zero-fill at disc edges, streams audio into a
/// staging WAV, and computes checksums on the corrected stream.
///
/// Secure-mode design notes (after cdparanoia/EAC/dbpoweramp):
/// - Drives cache audio reads, and an immediate re-read of the same sectors
///   is served from that cache — identical garbage twice looks "verified".
///   Compare mode therefore makes two *full separated passes* over the track
///   (a track is far larger than any drive cache). Targeted re-reads are
///   cache-busted only when timing shows the previous read actually came
///   from the cache (< 6 ms — cdparanoia's heuristic); a slow read already
///   proves medium access, and busting it would just wear the mechanism.
/// - Damaged regions make the drive retry internally for seconds per
///   request. The engine responds like the reference rippers: drop the
///   drive to a low speed (damaged media reads better slowly), bisect
///   failing requests so single bad sectors can't stall whole chunks, and
///   give up quickly per sector (zero-fill + report) instead of hammering.
/// - C2 mode trusts the drive's error pointers for triage (single pass),
///   only after `DiscRipper.probeC2` has validated the C2 data is real.
public struct TrackRipper: Sendable {
    let device: any CDDeviceIO
    let config: RipConfiguration
    /// Readable sector bounds of the audio area (0 ..< lead-out LBA).
    let readableSectors: Range<Int>
    let useC2: Bool
    let damage: DamageMap

    private static let bytesPerSector = SectorAreas.audioBytesPerSector
    /// Conservative bound on drive read-cache coverage, in sectors
    /// (cdparanoia's default cache model: 1200 sectors ≈ 2.8 MB ≈ 16 s).
    private static let cacheFlushDistance = 1200
    /// A read faster than this came from the drive cache (cdparanoia: 6 ms).
    private static let cacheFastThreshold: Duration = .milliseconds(6)
    /// A read slower than this means the drive is struggling internally;
    /// host-side retries add nothing beyond this point.
    private static let struggleThreshold: Duration = .seconds(2)
    /// Hard wall-clock budget for settling one sector/window: retries are
    /// pointless once the drive's own retry storms dominate each attempt.
    private static let settleTimeBudget: Duration = .seconds(10)
    /// Speed requested while inside a damaged region (≈ 4×). Damaged media
    /// reads markedly better at low speed (the XLD/dbpoweramp playbook).
    private static let damagedRegionSpeed: UInt16 = 706

    public init(
        device: any CDDeviceIO,
        config: RipConfiguration,
        readableSectors: Range<Int>,
        useC2: Bool,
        damage: DamageMap = DamageMap()
    ) {
        self.device = device
        self.config = config
        self.readableSectors = readableSectors
        self.useC2 = useC2
        self.damage = damage
    }

    /// Thrown when the drive's C2 flag rate is implausible — the track must
    /// be restarted in compare mode and C2 retired for this drive.
    struct C2DistrustError: Error {}

    /// Per-rip drive-state tracker (speed reduction happens once per track).
    private actor RipHealth {
        private(set) var slowed = false
        private var c2SectorsSeen = 0
        private var c2SectorsFlagged = 0

        /// True the first time a struggle is reported (caller then slows the drive).
        func noteStruggle() -> Bool {
            if slowed { return false }
            slowed = true
            return true
        }

        /// Tracks the C2 flag rate. A working drive flags a tiny fraction of
        /// sectors even on a bad disc; whole-chunk flagging means the drive
        /// is lying (one-shot probes can't catch intermittent liars).
        /// Returns true when C2 should no longer be believed.
        func noteC2(flagged: Int, of count: Int) -> Bool {
            c2SectorsSeen += count
            c2SectorsFlagged += flagged
            return c2SectorsSeen >= 150 && c2SectorsFlagged * 20 > c2SectorsSeen
        }

    }

    /// Confirmed-unreadable runs (absolute LBA ranges), shared across all
    /// tracks and passes of one disc operation: a failing read costs the
    /// drive's full internal retry storm, so damage charted once must never
    /// be probed again — not by the next chunk, not by the second compare
    /// pass, not by the verify-first secure re-rip.
    public actor DamageMap {
        private var runs: [Range<Int>] = []

        public init() {}

        func recordBadRun(_ run: Range<Int>) {
            guard !run.isEmpty else { return }
            runs.append(run)
        }

        func knownBadRuns(intersecting range: Range<Int>) -> [Range<Int>] {
            runs.compactMap { run in
                let overlap = run.clamped(to: range)
                return overlap.isEmpty ? nil : overlap
            }.sorted { $0.lowerBound < $1.lowerBound }
        }

        public var totalBadSectors: Int {
            runs.reduce(0) { $0 + $1.count }
        }
    }

    public func rip(
        track: TOCTrack,
        toc: TOC,
        isFirstAudio: Bool,
        isLastAudio: Bool,
        ctdbLeadingSkip: Int = 0,
        ctdbTrailingSkip: Int = 0,
        to wavURL: URL,
        onAudio: (@Sendable (Data) -> Void)? = nil,
        progress: @Sendable @escaping (RipProgress) -> Void
    ) async throws -> RippedTrack {
        let sectors = toc.sectorRange(of: track)
        let context = TrackContext(
            track: track,
            sectors: sectors,
            trackByteStart: sectors.lowerBound * Self.bytesPerSector + config.sampleOffset * 4,
            wavURL: wavURL,
            checksums: ChecksumAccumulator(
                totalSamples: sectors.count * 588,
                isFirstTrack: isFirstAudio,
                isLastTrack: isLastAudio,
                ctdbLeadingSkip: ctdbLeadingSkip,
                ctdbTrailingSkip: ctdbTrailingSkip
            ),
            onAudio: onAudio,
            progress: progress
        )

        let health = RipHealth()
        var result: RippedTrack
        if case .secure(let maxRetries, let agreeingPasses) = config.mode {
            if useC2 {
                do {
                    result = try await singlePassRip(context, health: health)
                } catch is C2DistrustError {
                    // The drive's C2 lied mid-track: restart this track in
                    // compare mode with fresh state.
                    result = try await twoPassCompareRip(
                        context, maxRetries: maxRetries, agreeingPasses: agreeingPasses, health: health
                    )
                    result.c2Distrusted = true
                }
            } else {
                result = try await twoPassCompareRip(
                    context, maxRetries: maxRetries, agreeingPasses: agreeingPasses, health: health
                )
            }
        } else {
            result = try await singlePassRip(context, health: health)
        }

        // Restore the configured speed if a damaged region slowed us down.
        if await health.slowed {
            try? await device.setSpeed(config.speedKBps ?? 0xFFFF)
        }
        return result
    }

    private struct TrackContext {
        let track: TOCTrack
        let sectors: Range<Int>
        let trackByteStart: Int
        let wavURL: URL
        var checksums: ChecksumAccumulator
        let onAudio: (@Sendable (Data) -> Void)?
        let progress: @Sendable (RipProgress) -> Void

        /// Corrected byte window of one output sector.
        func window(ofOutputSector index: Int) -> Range<Int> {
            (trackByteStart + index * 2352) ..< (trackByteStart + (index + 1) * 2352)
        }
    }

    // MARK: Burst and C2 single-pass path

    private func singlePassRip(_ context: TrackContext, health: RipHealth) async throws -> RippedTrack {
        var context = context
        let totalSectors = context.sectors.count
        let writer = try WAVWriter(url: context.wavURL, expectedDataBytes: totalSectors * 2352)
        var rereads = 0
        var unrecoverable: [Int] = []

        var outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = (context.trackByteStart + outputSector * Self.bytesPerSector)
                ..< (context.trackByteStart + (outputSector + chunk) * Self.bytesPerSector)

            let result = try await readChunk(for: byteRange, health: health, withC2: useC2)
            rereads += result.rereads
            unrecoverable.append(contentsOf: result.unrecoverableSectors)

            try writer.append(result.audio)
            context.checksums.update(result.audio)
            context.onAudio?(result.audio)

            outputSector += chunk
            context.progress(RipProgress(
                trackNumber: context.track.number,
                sectorsCompleted: outputSector,
                totalSectors: totalSectors,
                rereads: rereads
            ))
        }

        try writer.finish()
        return RippedTrack(
            trackNumber: context.track.number,
            wavURL: context.wavURL,
            checksums: context.checksums.finalize(),
            rereads: rereads,
            unrecoverableSectors: unrecoverable.sorted(),
            usedC2: useC2
        )
    }

    // MARK: Compare-mode two-pass path

    /// Pass 1 writes the track; pass 2 re-reads everything and compares
    /// per-sector CRCs. Sectors that differ between passes are settled by
    /// voting and patched into the WAV. Checksums come from the final file.
    private func twoPassCompareRip(
        _ context: TrackContext, maxRetries: Int, agreeingPasses: Int, health: RipHealth
    ) async throws -> RippedTrack {
        var context = context
        let totalSectors = context.sectors.count
        let progressTotal = totalSectors * 2
        var rereads = 1 // count the verification pass like before
        var unrecoverable: [Int] = []

        // Pass 1: write the WAV, remember a CRC per output sector.
        let writer = try WAVWriter(url: context.wavURL, expectedDataBytes: totalSectors * 2352)
        var sectorCRCs = [UInt32]()
        sectorCRCs.reserveCapacity(totalSectors)

        var outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = (context.trackByteStart + outputSector * Self.bytesPerSector)
                ..< (context.trackByteStart + (outputSector + chunk) * Self.bytesPerSector)
            let result = try await readChunk(for: byteRange, health: health, withC2: false)
            unrecoverable.append(contentsOf: result.unrecoverableSectors)
            try writer.append(result.audio)
            for s in 0 ..< chunk {
                sectorCRCs.append(CRC32.checksum(result.audio.subdata(
                    in: result.audio.startIndex + s * 2352 ..< result.audio.startIndex + (s + 1) * 2352
                )))
            }
            outputSector += chunk
            context.progress(RipProgress(
                trackNumber: context.track.number,
                sectorsCompleted: outputSector,
                totalSectors: progressTotal,
                rereads: 0
            ))
        }
        try writer.finish()

        // Force the second pass to the medium even for tracks smaller than
        // the drive cache.
        await flushCache(near: context.sectors.lowerBound)

        // Pass 2: re-read, compare, settle and patch mismatches.
        guard let patcher = try? FileHandle(forWritingTo: context.wavURL) else {
            throw RipError.cancelled
        }
        defer { try? patcher.close() }

        outputSector = 0
        while outputSector < totalSectors {
            try Task.checkCancellation()
            let chunk = min(config.chunkSectors, totalSectors - outputSector)
            let byteRange = (context.trackByteStart + outputSector * Self.bytesPerSector)
                ..< (context.trackByteStart + (outputSector + chunk) * Self.bytesPerSector)
            let result = try await readChunk(for: byteRange, health: health, withC2: false)

            for s in 0 ..< chunk {
                let secondBytes = result.audio.subdata(
                    in: result.audio.startIndex + s * 2352 ..< result.audio.startIndex + (s + 1) * 2352
                )
                let index = outputSector + s
                guard CRC32.checksum(secondBytes) != sectorCRCs[index] else { continue }

                let settled = try await settleWindow(
                    context.window(ofOutputSector: index),
                    initialCandidate: secondBytes,
                    maxRetries: maxRetries,
                    agreeingPasses: agreeingPasses,
                    health: health
                )
                rereads += settled.rereads
                if !settled.recovered {
                    unrecoverable.append(context.sectors.lowerBound + index)
                }
                try patcher.seek(toOffset: UInt64(44 + index * 2352))
                try patcher.write(contentsOf: settled.audio)
            }

            outputSector += chunk
            context.progress(RipProgress(
                trackNumber: context.track.number,
                sectorsCompleted: totalSectors + outputSector,
                totalSectors: progressTotal,
                rereads: rereads - 1
            ))
        }
        try patcher.close()

        // Checksums over the final, patched audio.
        let reader = try FileHandle(forReadingFrom: context.wavURL)
        defer { try? reader.close() }
        try reader.seek(toOffset: 44)
        while let data = try reader.read(upToCount: 4 << 20), !data.isEmpty {
            context.checksums.update(data)
            context.onAudio?(data)
        }

        return RippedTrack(
            trackNumber: context.track.number,
            wavURL: context.wavURL,
            checksums: context.checksums.finalize(),
            rereads: rereads,
            unrecoverableSectors: Array(Set(unrecoverable)).sorted(),
            usedC2: false
        )
    }

    // MARK: Resilient device reads

    /// Reads a sector range, surviving unreadable sectors.
    ///
    /// The cost model: a read that *fails* costs the drive's entire internal
    /// retry storm (1–2 minutes on some drives), so the budget is failing
    /// contacts, not sectors. Healthy spans are read with exponentially
    /// growing requests; damage is crossed by zero-filling exponentially
    /// growing blocks at one failing probe each, with the final block
    /// retro-bisected so run boundaries stay sector-exact. Confirmed runs
    /// are remembered and never touched again (pass 2, settles).
    private func resilientRead(
        _ sectors: Range<Int>, areas: SectorAreas, health: RipHealth
    ) async -> (data: Data, unrecoverable: [Int]) {
        let knownBad = await damage.knownBadRuns(intersecting: sectors)

        // Fast path: no known damage inside — try the whole range.
        if knownBad.isEmpty {
            let started = ContinuousClock.now
            if let buffer = try? await device.readSectors(sectors, areas: areas) {
                // Success, but slower than the drive's own retry storm
                // allows: drop to low speed for the rest of the track.
                if ContinuousClock.now - started > Self.struggleThreshold,
                   await health.noteStruggle() {
                    try? await device.setSpeed(Self.damagedRegionSpeed)
                }
                return (buffer.data, [])
            }
            if await health.noteStruggle() {
                try? await device.setSpeed(Self.damagedRegionSpeed)
                // One retry of the whole range at low speed.
                if let buffer = try? await device.readSectors(sectors, areas: areas) {
                    return (buffer.data, [])
                }
            }
        }

        return await mapDamage(sectors, areas: areas, health: health, knownBad: knownBad)
    }

    private func mapDamage(
        _ sectors: Range<Int>, areas: SectorAreas, health: RipHealth, knownBad: [Range<Int>]
    ) async -> (data: Data, unrecoverable: [Int]) {
        let stride = areas.bytesPerSector
        var out = Data(count: sectors.count * stride) // zero-filled canvas
        var bad: [Int] = []

        func fill(_ buffer: SectorBuffer, at lba: Int) {
            let dest = (lba - sectors.lowerBound) * stride
            out.replaceSubrange(dest ..< dest + buffer.data.count, with: buffer.data)
        }

        var cursor = sectors.lowerBound
        var goodStep = 8
        var consecutiveGoodSingles = 0

        while cursor < sectors.upperBound, !Task.isCancelled {
            // Confirmed damage: zero-fill without touching the device.
            if let run = knownBad.first(where: { $0.contains(cursor) }) {
                let span = cursor ..< min(run.upperBound, sectors.upperBound)
                bad.append(contentsOf: span)
                cursor = span.upperBound
                continue
            }
            let nextKnownBad = knownBad.map(\.lowerBound).filter { $0 > cursor }.min()
                ?? sectors.upperBound

            let n = min(goodStep, nextKnownBad - cursor, sectors.upperBound - cursor)
            if let buffer = try? await device.readSectors(cursor ..< cursor + n, areas: areas) {
                fill(buffer, at: cursor)
                cursor += n
                if goodStep == 1 {
                    consecutiveGoodSingles += 1
                    if consecutiveGoodSingles >= 16 { goodStep = 8 }
                } else {
                    goodStep = min(goodStep * 2, config.chunkSectors)
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
            let runStart = cursor
            var zeroBlock = 1
            while cursor < sectors.upperBound, !Task.isCancelled {
                let blockEnd = min(cursor + zeroBlock, sectors.upperBound)
                bad.append(contentsOf: cursor ..< blockEnd)
                let lastBlock = cursor ..< blockEnd
                cursor = blockEnd
                guard cursor < sectors.upperBound else { break }

                if let probe = try? await device.readSectors(cursor ..< cursor + 1, areas: areas) {
                    fill(probe, at: cursor)
                    cursor += 1
                    // The run ended inside the last zero block: recover its
                    // readable tail so the boundary is sector-exact.
                    let recovered = await recoverTail(of: lastBlock, areas: areas)
                    if let recovered {
                        fill(recovered.buffer, at: recovered.from)
                        bad.removeAll { $0 >= recovered.from && $0 < lastBlock.upperBound }
                    }
                    let runEnd = recovered?.from ?? lastBlock.upperBound
                    await damage.recordBadRun(runStart ..< runEnd)
                    break
                }
                zeroBlock = min(zeroBlock * 2, 32)
            }
            if cursor >= sectors.upperBound {
                // Run reaches the end of this request; it may continue into
                // the next chunk (which will pay one probe to find out).
                await damage.recordBadRun(runStart ..< sectors.upperBound)
            }
            goodStep = 1
            consecutiveGoodSingles = 0
        }

        return (out, bad.sorted())
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

    // MARK: Chunk reads

    private struct ChunkResult {
        var audio: Data
        var rereads: Int
        var unrecoverableSectors: [Int]
    }

    /// Returns the bytes of the virtual disc byte stream for `byteRange`,
    /// zero-filled where the range falls outside the readable sector bounds.
    /// In C2 mode, flagged sectors are settled inline.
    private func readChunk(for byteRange: Range<Int>, health: RipHealth, withC2: Bool) async throws -> ChunkResult {
        let bps = Self.bytesPerSector
        let firstSector = byteRange.lowerBound.flooredDivision(by: bps)
        let lastSector = (byteRange.upperBound + bps - 1).flooredDivision(by: bps)
        let span = firstSector ..< lastSector
        let clamped = span.clamped(to: readableSectors)

        var raw = Data(count: span.count * bps)
        var rereads = 0
        var unrecoverable: [Int] = []

        if !clamped.isEmpty {
            let read: ChunkResult
            if case .secure(let maxRetries, let agreeingPasses) = config.mode, withC2 {
                read = try await readWithC2(
                    sectors: clamped, maxRetries: maxRetries, agreeingPasses: agreeingPasses, health: health
                )
            } else {
                let resilient = await resilientRead(clamped, areas: .user, health: health)
                read = ChunkResult(
                    audio: resilient.data, rereads: 0, unrecoverableSectors: resilient.unrecoverable
                )
            }
            rereads = read.rereads
            unrecoverable = read.unrecoverableSectors
            let dest = (clamped.lowerBound - firstSector) * bps
            raw.replaceSubrange(dest ..< dest + read.audio.count, with: read.audio)
        }

        let sliceStart = byteRange.lowerBound - firstSector * bps
        return ChunkResult(
            audio: raw.subdata(in: sliceStart ..< sliceStart + byteRange.count),
            rereads: rereads,
            unrecoverableSectors: unrecoverable
        )
    }

    private func readWithC2(
        sectors: Range<Int>, maxRetries: Int, agreeingPasses: Int, health: RipHealth
    ) async throws -> ChunkResult {
        let areas: SectorAreas = [.user, .errorFlags]
        let resilient = await resilientRead(sectors, areas: areas, health: health)
        let buffer = SectorBuffer(
            startLBA: sectors.lowerBound, sectorCount: sectors.count, areas: areas, data: resilient.data
        )

        // Sanity-check the flag rate before acting on a single flag: an
        // implausible rate means the drive's C2 is lying, and settling
        // lie-flagged sectors would grind the mechanism for nothing.
        let flagged = (0 ..< sectors.count).count { buffer.hasC2Error(sector: $0) }
        if await health.noteC2(flagged: flagged, of: sectors.count) {
            throw C2DistrustError()
        }

        var audio = Data(capacity: sectors.count * Self.bytesPerSector)
        var rereads = 0
        var unrecoverable = resilient.unrecoverable

        for index in 0 ..< sectors.count {
            let lba = sectors.lowerBound + index
            // Sectors zero-filled by the resilient read are already reported.
            if buffer.hasC2Error(sector: index), !unrecoverable.contains(lba) {
                let settled = try await settleSector(
                    lba: lba, maxRetries: maxRetries, agreeingPasses: agreeingPasses, health: health
                )
                rereads += settled.rereads
                if !settled.recovered { unrecoverable.append(lba) }
                audio.append(settled.audio)
            } else {
                audio.append(buffer.audio(sector: index))
            }
        }
        return ChunkResult(audio: audio, rereads: rereads, unrecoverableSectors: unrecoverable)
    }

    // MARK: Settling

    private struct SettledData {
        var audio: Data
        var rereads: Int
        var recovered: Bool
    }

    /// Re-reads a single device sector (C2 path) until `agreeingPasses`
    /// clean byte-identical reads agree. Cache-busts only when timing shows
    /// the previous read was served from cache; caps the effort as soon as
    /// the drive is visibly struggling (its internal retries dwarf ours).
    private func settleSector(
        lba: Int, maxRetries: Int, agreeingPasses: Int, health: RipHealth
    ) async throws -> SettledData {
        var counts: [Data: Int] = [:]
        var rereads = 0
        var effectiveMax = maxRetries
        var previousWasCacheFast = true // the triggering read just cached this sector
        let deadline = ContinuousClock.now + Self.settleTimeBudget

        while rereads < effectiveMax, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if previousWasCacheFast {
                await flushCache(near: lba)
            }
            let started = ContinuousClock.now
            let buffer = try? await device.readSectors(lba ..< lba + 1, areas: [.user, .errorFlags])
            let elapsed = ContinuousClock.now - started
            rereads += 1
            previousWasCacheFast = elapsed < Self.cacheFastThreshold

            if elapsed > Self.struggleThreshold {
                effectiveMax = min(effectiveMax, rereads + 1)
                if await health.noteStruggle() {
                    try? await device.setSpeed(Self.damagedRegionSpeed)
                }
            }

            guard let buffer, !buffer.hasC2Error(sector: 0) else { continue }
            let audio = buffer.audio(sector: 0)
            let count = (counts[audio] ?? 0) + 1
            counts[audio] = count
            if count >= agreeingPasses {
                return SettledData(audio: audio, rereads: rereads, recovered: true)
            }
        }

        let best = counts.max { $0.value < $1.value }?.key ?? Data(count: Self.bytesPerSector)
        return SettledData(audio: best, rereads: rereads, recovered: false)
    }

    /// Settles one corrected output-sector window (compare path): re-reads
    /// its input span until `agreeingPasses` identical windows agree, with
    /// the same timing-based cache busting and struggle caps.
    private func settleWindow(
        _ byteRange: Range<Int>,
        initialCandidate: Data?,
        maxRetries: Int,
        agreeingPasses: Int,
        health: RipHealth
    ) async throws -> SettledData {
        var counts: [Data: Int] = [:]
        if let initialCandidate { counts[initialCandidate] = 1 }
        var rereads = 0
        var effectiveMax = maxRetries
        var previousWasCacheFast = true
        let deadline = ContinuousClock.now + Self.settleTimeBudget

        let bps = Self.bytesPerSector
        let firstSector = byteRange.lowerBound.flooredDivision(by: bps)
        let lastSector = (byteRange.upperBound + bps - 1).flooredDivision(by: bps)
        let clamped = (firstSector ..< lastSector).clamped(to: readableSectors)

        while rereads < effectiveMax, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if previousWasCacheFast {
                await flushCache(near: max(firstSector, readableSectors.lowerBound))
            }

            var raw = Data(count: (lastSector - firstSector) * bps)
            let started = ContinuousClock.now
            let buffer = clamped.isEmpty ? nil : try? await device.readSectors(clamped, areas: .user)
            let elapsed = ContinuousClock.now - started
            rereads += 1
            previousWasCacheFast = elapsed < Self.cacheFastThreshold

            if elapsed > Self.struggleThreshold {
                effectiveMax = min(effectiveMax, rereads + 1)
                if await health.noteStruggle() {
                    try? await device.setSpeed(Self.damagedRegionSpeed)
                }
            }

            if let buffer {
                let dest = (clamped.lowerBound - firstSector) * bps
                let audio = buffer.allAudio()
                raw.replaceSubrange(dest ..< dest + audio.count, with: audio)
            } else if !clamped.isEmpty {
                continue // read failed; retry counts toward the cap
            }

            let sliceStart = byteRange.lowerBound - firstSector * bps
            let window = raw.subdata(in: sliceStart ..< sliceStart + byteRange.count)
            let count = (counts[window] ?? 0) + 1
            counts[window] = count
            if count >= agreeingPasses {
                return SettledData(audio: window, rereads: rereads, recovered: true)
            }
        }

        let best = counts.max { $0.value < $1.value }?.key ?? Data(count: byteRange.count)
        return SettledData(audio: best, rereads: rereads, recovered: false)
    }

    /// Evicts the drive's read cache with a *small* backseek — just beyond
    /// the modeled cache window. Same flush effect as a cross-disc jump on
    /// read-ahead caches, a fraction of the head travel.
    private func flushCache(near lba: Int) async {
        let area = readableSectors
        guard area.count > 1 else { return }
        var target = lba - Self.cacheFlushDistance
        if target < area.lowerBound {
            target = min(lba + Self.cacheFlushDistance, area.upperBound - 1)
        }
        _ = try? await device.readSectors(target ..< target + 1, areas: .user)
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
