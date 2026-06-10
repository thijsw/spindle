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
- **FLAC + ALAC only.** Both via Apple's Core Audio. No MP3 in v1 (Apple ships
  no MP3 encoder; LAME is LGPL and the project avoids non-MIT dependencies).
- **Local folder + SFTP only.** No plain FTP (Apple removed its FTP APIs; a
  folder destination covers Finder-mounted SMB/NFS/WebDAV NAS shares).
- **Citadel (MIT) is the only third-party dependency.** Its types aren't
  Sendable-annotated, so the `Transfer` module compiles in Swift 5 language
  mode; the `SFTPDestination` actor provides the real isolation.
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
- `RipEngine` — secure/burst loop, ±offset with edge zero-fill, CRC32 +
  AccurateRip v1/v2 + CTDB-skip checksums, WAV staging
- `Metadata` — pure-Swift MusicBrainz DiscID (validated against libdiscid
  vectors), throttled WS/2 client (1 req/s + User-Agent are MANDATORY),
  release scorer, CAA client, CD-TEXT via DRCDTextBlock
- `Verification` — CTDB lookup2 v3 client + verdict matching
- `Encoding` — Core Audio encoders + pure-Swift FLAC metadata block rewriter
  (Vorbis comments, PICTURE, STREAMINFO MD5 patched from our own PCM hash —
  Apple's encoder can't tag FLAC at all)
- `Naming` — `{token}` / `[conditional group]` templates + path sanitizer
- `Transfer` — Destination protocol (.part upload → rename), folder + SFTP,
  Keychain
- `SpindleCore` — `PipelineCoordinator` actor; drive-bound stages are exclusive
  per drive, post-rip stages run detached (2 encode / 1 transfer slots), the
  release picker NEVER blocks the rip (continuation-based `MetadataGate`)

## Hard-won gotchas

- The Apple SuperDrive (HL-DT-ST GX50N mechanism) has INTERMITTENTLY broken
  C2: sometimes whole transfers are garbage, sometimes the probe sees healthy
  data and the drive then flags perfect sectors wholesale mid-track (and C2
  reads take ~2.7 s each). No probe catches this — the runtime flag-rate
  monitor in TrackRipper (>5% flagged ⇒ C2DistrustError ⇒ compare-mode
  restart, verdict persisted in Preferences.drivesWithUnreliableC2) is the
  real defense. Confirmed drive offset for this unit: +6 (CTDB confidence
  ~29k via scan-offset). Sustained throughput: ~6.8× burst, ~3.4×
  compare-mode secure; track 1/13 of the test disc have genuine edge damage.
- Never diagnose drive stalls by theorizing: `sample <pid> 5` while hung
  shows exactly which engine path is blocked in ioctl.

- `AVAudioFile.read(into:)` throws a spurious `nilError` at exact EOF — every
  read loop must guard `framePosition < length`. Already handled in Encoding;
  do the same in any new audio loop.
- DKIOCCDREAD `offset` is `LBA × 2352` regardless of which sector areas are
  requested; returned per-sector layout is audio(2352) + C2(294) + subQ(16).
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
- `cd SpindleCore && swift build && swift test` — core + Swift Testing suite.
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
