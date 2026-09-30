# Spindle — project memory

Native macOS CD ripper: insert disc → accurate rip (raw IOKit CDDA reads with
C2 re-reading + drive offset correction) → MusicBrainz metadata + Cover Art
Archive → FLAC/ALAC encode with full Picard-style tags → deliver to local
folder or SFTP (Navidrome use case) → eject, next disc. Built June 2026 from
the plan in `~/.claude/plans/i-like-you-to-staged-sphinx.md`.

## Settled decisions (don't relitigate)

- **Developer ID, NOT sandboxed.** The App Store sandbox cannot open
  `/dev/rdiskN`, so secure ripping and the zero-click batch workflow are
  impossible there. A sandboxed burst-rip MAS variant remains possible later —
  the rip engine sits behind the `CDDeviceIO` protocol for exactly that reason.
- **FLAC + ALAC + AAC (256 kbps) only.** All via Apple's Core Audio; one
  format per rip, chosen in Settings. No MP3 (Apple ships no MP3 encoder;
  LAME is LGPL and the project avoids non-MIT dependencies).
- **Local folder + SFTP only.** No plain FTP (Apple removed its FTP APIs; a
  folder destination covers Finder-mounted SMB/NFS/WebDAV NAS shares).
- **Two third-party dependencies: Citadel and Sparkle (both permissive).**
  Citadel (MIT, for SFTP) is a `SpindleCore` package dep; its types aren't
  Sendable-annotated, so the `Transfer` module compiles in Swift 5 language
  mode and the `SFTPDestination` actor provides the real isolation. Sparkle
  (the app shell's auto-updater, added for v0.2.0) is an *app-target* SPM dep
  in `Spindle.xcodeproj` only — `SpindleCore` stays dependency-light. Sparkle
  was a deliberate amendment to the old "Citadel only" rule (user-approved,
  June 2026); the bar remains permissive licenses only (no LGPL/copyleft).
- **AccurateRip is deliberately absent** — its database requires written
  permission (commercial apps need a paid license). Verification uses the
  public CUETools DB (db.cue.tools) instead; `Verification.RipVerifier` is the
  protocol seam where AccurateRip can plug in once permission exists.

## Architecture map

`SpindleCore/` is the SPM package with all logic; `Spindle/` is the thin
SwiftUI app shell built by `Spindle.xcodeproj`.

- `CIOCD` — C shim for the IOCDMedia BSD ioctls (Swift can't call variadic ioctl)
- `DiscDrive` — DiskArbitration monitor (incl. cddafs mount-approval dissent),
  `CDDrive` actor on `/dev/rdiskN`, full-TOC parser, drive identity/offset table
- `RipEngine` — `DiscRipper` → `TrackRipper` (orchestration only) →
  `ResilientReader` (damage mapping, run crossing, cache flush, slow-down)
  + `Settler` (voting re-reads) + `SectorSpan` (offset byte-window ↔ sector
  math); `DamageMap` shared across passes; zlib-backed CRC32 + AccurateRip
  v1/v2 + CTDB-skip checksums (`CTDBWindow.trackWindows(for:)` is the ONE
  source of the per-track windows); WAV staging
- `Net` — Foundation-only `HTTPFetcher` (session, User-Agent, HTTP check)
  shared by the MusicBrainz, Cover Art Archive and CTDB clients
- `Metadata` — pure-Swift MusicBrainz DiscID (validated against libdiscid
  vectors), throttled WS/2 client (1 req/s + User-Agent are MANDATORY; the
  throttle reserves its slot BEFORE sleeping so concurrent callers can't
  collapse onto one instant), release scorer, `MBRelease.bestMedium`, CAA
  client, CD-TEXT via DRCDTextBlock
- `Verification` — CTDB lookup2 v3 client + verdict matching
- `Encoding` — one `Transcoder` loop for every format; `TrackTags.fields`
  is the canonical Picard tag set (`TagKey`), mapped to Vorbis comments in
  FLAC and to iTunes atoms + `----:com.apple.iTunes:*` freeform atoms in
  M4A (so ALAC/AAC carry MusicBrainz IDs too); pure-Swift FLAC metadata
  block rewriter (STREAMINFO MD5 patched from our own PCM hash — Apple's
  encoder can't tag FLAC at all)
- `Naming` — `{token}` / `[conditional group]` templates + path sanitizer
- `Transfer` — Destination protocol (.part upload → rename), folder + SFTP,
  Keychain; SSH host keys verified trust-on-first-use (SHA-256 fingerprint
  pinned in Keychain via `HostKeyStore`; mismatch ⇒ `DestinationError
  .hostKeyMismatch`, "Forget Saved Host Key" in Settings re-pins)
- `SpindleCore` — `PipelineCoordinator` actor; drive-bound stages are exclusive
  per drive, post-rip stages run detached (2 encode / 1 transfer slots, each
  held only for its own stage), the release picker NEVER blocks the rip
  (`MetadataGate` resumes EVERY waiter — identify's art fetch and the
  processing stage both park there). Preferences are snapshotted per job
  (destination is read at delivery time). Shared with the CLI: `AlbumEncoder`
  (walks a pure `DeliveryPlan`), `ReleaseLookup`, `JobPresentation` /
  `DisplayFormat`, `DestinationDraft`. The debug CLI is one file per command
  under `spindle-cli/Commands/`.

## Hard-won gotchas

- The Apple SuperDrive (HL-DT-ST GX50N mechanism) has INTERMITTENTLY broken
  C2: sometimes whole transfers are garbage, sometimes the probe sees healthy
  data and the drive then flags perfect sectors wholesale mid-track (and C2
  reads take ~2.7 s each). No probe catches this — the runtime flag-rate
  monitor in TrackRipper (>5% flagged ⇒ C2DistrustError ⇒ compare-mode
  restart, verdict persisted in Preferences.drivesWithUnreliableC2) is the
  real defense. Confirmed drive offset for this unit: +6 (13/13 tracks,
  CTDB confidence 34,230 via scan-offset). Sustained throughput: ~6.8×
  burst, ~3.4× compare-mode secure.
- CTDB edge windows (calibrated against the live DB, confidence ~2600 —
  don't re-derive from the GPL source, its units are ambiguous): first track
  skips ONE FULL stride (5880 samples); last track ends 5880 +
  (totalSamples % 5880) before lead-out; middle tracks are exact
  [start, nextStart). End-to-end hardware validation passed: full disc
  ripped + 13/13 CTDB-verified in 5.3 min, encoded to a tagged FLAC
  library.
- A rip that is suddenly slow (~1×) AND makes the drive click/seek loudly
  means a second reader: Music.app auto-imports an inserted CD (holds
  `/dev/rdisk4` open, unmount dissents, so the hold silently fails). Check
  `lsof /dev/rdisk4`; the fix is quitting Music (or Music → Settings →
  General → "On CD insert: Ignore"). The engine sample shows 98% time inside
  `ciocd_read` with uniform ~1.5 s reads, no retries — found 2026-09-30.
- Never diagnose drive stalls by theorizing: `sample <pid> 5` while hung
  shows exactly which engine path is blocked in ioctl.
- UI hang post-mortem (the Settings beach-ball): the root cause was a
  SwiftUI feedback loop — `MenuBarExtra(isInserted: binding)` drives the
  binding's setter at display rate, and `@Observable` notifies on EVERY
  assignment even when unchanged, so writing the same value back re-rendered
  all preference observers ~42×/s (proven by file-logging the setter: 1104
  writes/26 s). Fix: guard binding setters that write into @Observable state
  to assign only on real change. General lesson: SwiftUI GUI hangs are not
  guessable — `sample` the hung main thread for the view, then file-log
  (not stdout — GUI stdout isn't captured; not _printChanges — suppressed
  outside Xcode) the suspected mutation to count it. AppModel split: live
  rip state (jobs/art) vs SettingsStore (preferences) so Settings never
  re-renders on rip churn.
- Damaged media economics: a FAILING read costs the drive's internal retry
  storm (1–2 min on the SuperDrive) and cannot be interrupted from
  userspace. The engine therefore budgets failing contacts (damage-run
  mapping + continuation in TrackRipper, shared DamageMap across passes)
  and enforces a per-track wall-clock budget (RipConfiguration
  .trackTimeLimit, default 5 min; CLI --give-up) — an unreadable track is
  abandoned (failedTracks) so the disc keeps moving. Tested against a
  scratched Adele "21" disc whose track 1 needed ~20 min even with run
  mapping.

- DiskArbitration's `DAReturn` is a signed `mach_error_t`: every dissent code
  (0xF8DA00xx) is NEGATIVE as an `Int32`, so `UInt32(status)` traps. That trap
  crashed v0.1.0 mid-batch on eject. Also, `DADiskCreateFromBSDName` returns a
  disk object for media that is already gone; only `DADiskCopyDescription`
  (nil) tells them apart, and unmount/eject on such a disk dissents
  `kDAReturnBadArgument` — synchronously, from inside the DADiskEject call.

- `AVAudioFile.read(into:)` throws a spurious `nilError` at exact EOF — every
  read loop must guard `framePosition < length`. Already handled in Encoding;
  do the same in any new audio loop.
- DKIOCCDREAD `offset` is `LBA × 2352` regardless of which sector areas are
  requested; returned per-sector layout is audio(2352) + C2(294) + subQ(16).
- DKIOCCDREADTOC with a 64 KB buffer fails with EIO on the SuperDrive (found
  in the 2026-09-30 smoke test — the disc looked unreadable). `CDDrive.readTOC`
  asks for 4 KB and only grows the request when the answer filled the buffer
  (CD-TEXT, format 5, can need ~36 KB).
- TOC parsing uses `formatAsTime=1` (MSF) and `LBA = MSF − 150`; MusicBrainz
  offsets are `LBA + 150`; CTDB toc param is plain LBAs with data tracks
  prefixed `-`, lead-out appended.
- CTDB track CRCs skip the first 2940 samples of track 1 and the last
  `2940 + (totalSamples % 2940)` of the last track (semantics read from
  CUETools source — facts only, it's GPL).
- macOS resolves `/tmp` → `/private/tmp`: always `resolvingSymlinksInPath()`
  before computing relative paths.

## Build & test

- Xcode 26.3 is installed and licensed (since June 2026); no `DEVELOPER_DIR`
  workaround needed anymore.
- `cd SpindleCore && swift build && swift test` — core + Swift Testing suite
  (~130 tests, ~6 s). If the build fails on a precompiled header from another
  checkout path (the repo was moved once), `rm -rf SpindleCore/.build` and
  retry. A killed/hung `swift test` leaves a SwiftPM lock on `.build` that
  makes later runs silently wait — `pkill -f swift-test` first. macOS has no
  `timeout`; use `perl -e 'alarm 300; exec @ARGV' swift test`.
- Test conventions: shared fixtures live in `Tests/.../Support/`
  (`Fixtures.swift`: `makeTOC`, `expectedAudio`, `canonicalCTDBEntry`,
  `StaticCTDBVerifier`, `makeTestAlbum`, `withTempDir`; `StubHTTP.swift`:
  per-test `HTTPStub` for the web clients; `MockCDDevice`). Pipeline tests
  use an `EventRecorder` — never cancel a `for await` on the coordinator's
  single-consumer event stream, it finishes the stream.
- `xcodebuild -project Spindle.xcodeproj -scheme Spindle build` — the app.
  The pbxproj is hand-authored (objectVersion 77, synchronized folder for
  `Spindle/`, local package ref to `SpindleCore`); edit it textually.
- `Scripts/make-app.sh [release]` → `dist/Spindle.app`; `notarize.sh` and
  `make-dmg.sh` for distribution (need the user's Developer ID certificate).
- Debug CLI: `swift run spindle-cli toc|discid|identify|rip|encode|push`
  (run from `SpindleCore/`). `identify --toc "…"` and `encode --toc "…"` work
  with no disc; the libdiscid reference TOC in the tests resolves to Beastie
  Boys' Hello Nasty and is handy for live MusicBrainz/CTDB checks.

## Still unverified (no optical drive was attached during development)

Real DKIOCCDREAD/TOC ioctls, C2 probing on real drives, drive offsets,
CD-TEXT reads, eject/mount-dissent flow, SuperDrive quirks, and SFTP against
the user's actual Navidrome server. First hardware session: `spindle-cli toc`,
`discid` (compare with musicbrainz.org), `rip` (compare CRCs with an XLD rip
of the same disc/drive to confirm the offset).
