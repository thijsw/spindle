import Foundation
import Metadata
import Testing
import Transfer

@testable import SpindleCore

@Suite struct DestinationDraftTests {
    @Test func roundTripsEveryKind() {
        let folder = DestinationConfig.localFolder(path: "/Volumes/Music")
        #expect(DestinationDraft(folder).config == folder)

        let sftp = DestinationConfig.sftp(SFTPConfig(
            host: "nas", port: 2222, username: "me",
            authentication: .privateKeyFile(path: "~/.ssh/id_ed25519"), remotePath: "/srv/music"
        ))
        let draft = DestinationDraft(sftp)
        #expect(draft.kind == .sftp && draft.usesKeyFile && draft.keyFile == "~/.ssh/id_ed25519")
        #expect(draft.config == sftp)
        #expect(draft.keychainAccount == "me@nas:2222")

        #expect(DestinationDraft(nil).config == nil)
    }

    @Test func incompleteDraftsProduceNoConfig() {
        var draft = DestinationDraft(nil)
        draft.kind = .sftp
        draft.host = "nas"
        #expect(draft.config == nil, "no user yet")
        draft.username = "me"
        #expect(draft.config == .sftp(SFTPConfig(host: "nas", username: "me", remotePath: ".")), "empty path → login dir")
        draft.kind = .folder
        #expect(draft.config == nil, "empty folder path")
    }
}

@Suite struct JobPresentationTests {
    private func job(stage: JobStage, album: String? = nil, tracks: [TrackState] = []) -> JobSnapshot {
        JobSnapshot(
            id: JobID(), bsdName: "disk4", stage: stage, discID: nil,
            album: album.map { ResolvedAlbum(album: $0, albumArtist: "A", tracks: []) },
            hasArt: false, tracks: tracks, candidates: [], verificationSummary: nil,
            startedAt: Date(), finishedAt: nil
        )
    }

    @Test func idleTextDependsOnDestination() {
        #expect(JobPresentation.statusText(jobs: [], transferFraction: [:], transferRate: [:], hasDestination: true) == "Ready — insert a disc")
        #expect(JobPresentation.statusText(jobs: [], transferFraction: [:], transferRate: [:], hasDestination: false).contains("No destination"))
        #expect(JobPresentation.menuBarSummary(jobs: [job(stage: .completed)]) == "Waiting for a disc")
    }

    @Test func uploadingBeatsEncodingBeatsRipping() {
        let ripping = job(stage: .ripping, album: "Rip", tracks: [
            TrackState(number: 1, title: "a", durationSeconds: 1, status: .ripped),
            TrackState(number: 2, title: "b", durationSeconds: 1, status: .ripping(0.4)),
            TrackState(number: 3, title: "c", durationSeconds: 1),
        ])
        let uploading = job(stage: .transferring, album: "Up")
        let text = JobPresentation.statusText(
            jobs: [uploading, ripping], transferFraction: [uploading.id: 0.5], transferRate: [uploading.id: 2_500_000],
            hasDestination: true
        )
        #expect(text == "Uploading Up — 50% · 2.5 MB/s")
        #expect(
            JobPresentation.statusText(jobs: [ripping], transferFraction: [:], transferRate: [:], hasDestination: true)
                == "Ripping Rip — track 2 of 3"
        )
        #expect(JobPresentation.menuBarSummary(jobs: [uploading, ripping]) == "A — Rip — Ripping")
    }

    @Test func formats() {
        #expect(DisplayFormat.minutesSeconds(187.4) == "3:07")
        #expect(DisplayFormat.minutesSeconds(59.6) == "1:00")
        #expect(DisplayFormat.transferRate(480_000) == "480 KB/s")
        #expect(DisplayFormat.transferRate(12_345_678) == "12.3 MB/s")
    }
}
