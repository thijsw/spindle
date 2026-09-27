import DiscDrive
@testable import Encoding
import Foundation
import Metadata
import Testing

@testable import SpindleCore

@Suite struct DriveIdentityTests {
    @Test func offsetKeyFollowsTheMechanism() {
        let superDrive = DriveIdentity(vendor: "Apple", product: "SuperDrive", revision: "1.0", mechanism: "HL-DT-ST DVDRW GX50N")
        #expect(superDrive.offsetKey == "HL-DT-ST DVDRW GX50N", "offsets belong to the mechanism, not the marketing name")
        #expect(superDrive.displayName == "Apple SuperDrive (HL-DT-ST DVDRW GX50N)")

        let plain = DriveIdentity(vendor: "PIONEER", product: "BD-RW BDR-XD05", revision: "1.02")
        #expect(plain.offsetKey == "PIONEER BD-RW BDR-XD05")
        #expect(plain.displayName == "PIONEER BD-RW BDR-XD05")
    }

    @Test func suggestionsAreDeterministicAndPreferTheMechanism() {
        let superDrive = DriveIdentity(vendor: "Apple", product: "SuperDrive", revision: "", mechanism: "HL-DT-ST DVDRW GX50N")
        #expect(DriveOffsetTable.suggestion(for: superDrive)?.samples == 6)
        let pioneer = DriveIdentity(vendor: "PIONEER", product: "DVD-RW DVR-216D", revision: "")
        #expect(DriveOffsetTable.suggestion(for: pioneer)?.samples == 667)
        // Two families in one string resolve the same way every time.
        let hybrid = DriveIdentity(vendor: "MATSHITA", product: "clone of a PIONEER", revision: "")
        let repeated = (0 ..< 20).map { _ in DriveOffsetTable.suggestion(for: hybrid)?.samples }
        #expect(Set(repeated) == [102], "first listed family wins, deterministically")
        #expect(DriveOffsetTable.suggestion(for: DriveIdentity(vendor: "ACME", product: "X", revision: "")) == nil)
    }
}

@Suite struct FLACMetadataRobustnessTests {
    @Test func rejectsNonFLACAndTruncatedFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let notFLAC = dir.appendingPathComponent("a.flac")
        try Data("RIFF....WAVEfmt ".utf8).write(to: notFLAC)
        #expect(throws: EncodingError.self) { try FLACMetadata.parse(fileURL: notFLAC) }

        // Valid magic, then a STREAMINFO header claiming more bytes than exist.
        let truncated = dir.appendingPathComponent("b.flac")
        try (Data("fLaC".utf8) + Data([0x80, 0x00, 0x00, 0x22]) + Data(count: 5)).write(to: truncated)
        #expect(throws: EncodingError.self) { try FLACMetadata.parse(fileURL: truncated) }
    }
}

@Suite struct JobStoreTests {
    private func record(_ album: String, at date: Date) -> JobRecord {
        var snapshot = JobSnapshot(
            id: JobID(), bsdName: "disk4", stage: .completed, discID: nil,
            album: ResolvedAlbum(album: album, albumArtist: "A", tracks: []),
            hasArt: false, tracks: [], candidates: [], verificationSummary: "ok",
            startedAt: date, finishedAt: date
        )
        snapshot.stage = .completed
        return JobRecord(snapshot: snapshot)
    }

    @Test func persistsMostRecentFirstAndTrimsToTheLimit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = JobStore(directory: dir, limit: 3)
        for n in 1 ... 5 {
            await store.append(record("Album \(n)", at: Date(timeIntervalSince1970: Double(n))))
        }
        #expect(await store.history().map(\.album) == ["Album 5", "Album 4", "Album 3"], "trimmed, newest first")

        let reloaded = JobStore(directory: dir, limit: 3)
        #expect(await reloaded.history().map(\.album) == ["Album 5", "Album 4", "Album 3"], "survives a relaunch")
        #expect(await reloaded.history().first?.finishedAt == Date(timeIntervalSince1970: 5), "dates round-trip (ISO 8601)")
    }

    @Test func malformedHistoryStartsEmptyInsteadOfCrashing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("history.json"))
        let store = JobStore(directory: dir)
        #expect(await store.history().isEmpty)
    }
}
