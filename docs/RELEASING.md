# Releasing Spindle

Releases are built by the [`Release`](../.github/workflows/release.yml) GitHub
Actions workflow. Pushing a version tag builds, signs, notarizes and packages
`Spindle.dmg`, then attaches it to the matching GitHub Release where anyone can
download it.

## Cutting a release

```sh
git tag v1.0.0          # use the version you're shipping
git push origin v1.0.0
```

The workflow runs on a macOS runner and, when it finishes, the
[Releases page](../../releases) has a new release with the `.dmg` attached and
auto-generated notes. You can also trigger it manually from the **Actions** tab
(*Run workflow*); a manual run uploads the DMG as a build artifact but does not
create a Release.

The tag drives the app's version: `v1.2.3` stamps `CFBundleShortVersionString`
= `1.2.3` (and the run number as `CFBundleVersion`) into `Info.plist` before
building, so the About box and the DMG name match the release. The version in
the checked-in `Info.plist` is only the development default. For a versioned
local build, run `Scripts/set-version.sh <version> [build]` before
`Scripts/make-app.sh` (it edits `Info.plist` — don't commit that change).

## Signing secrets (required for public builds)

Without these, the workflow still produces a `.dmg`, but it is **unsigned and
not notarized** — macOS Gatekeeper will refuse to open it. Configure them under
**Settings → Secrets and variables → Actions** so downloaders get a build that
opens with a double-click.

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE` | Your *Developer ID Application* certificate exported as a `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_PWD` | The password you set when exporting the `.p12` |
| `MACOS_SIGN_IDENTITY` | The identity name, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID` | The Apple ID email used for notarization |
| `NOTARY_TEAM_ID` | Your Apple Developer Team ID |
| `NOTARY_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID |

### Where each value comes from

All of these come from an Apple Developer account, not from this repo.

> **Prerequisite:** a paid [Apple Developer Program](https://developer.apple.com/programs/)
> membership ($99/year). The free Apple ID tier cannot create a Developer ID
> certificate or notarize, so macOS would block the app for everyone who
> downloads it.

Check what you already have on your Mac:

```sh
security find-identity -v -p codesigning   # lists signing identities (empty = none yet)
```

#### `MACOS_SIGN_IDENTITY`, `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`

These three all come from one **Developer ID Application** certificate. Create
it once:

1. In **Xcode → Settings → Accounts**, add your Apple ID, select your team,
   click **Manage Certificates**, then **+** → **Developer ID Application**.
   This creates the certificate and its private key in your login keychain.
   (Web alternative: developer.apple.com → Certificates → **+** → *Developer ID
   Application* — but the Xcode route sets up the private key for you.)

2. Get the identity string:

   ```sh
   security find-identity -v -p codesigning
   ```

   The quoted name is `MACOS_SIGN_IDENTITY`, e.g.
   `Developer ID Application: Your Name (A1B2C3D4E5)`.

3. Export the certificate for CI: in **Keychain Access**, find that certificate,
   confirm it expands to show a private key, right-click → **Export**, and save
   a `.p12`. The export password you set is **`MACOS_CERTIFICATE_PWD`**.

4. Base64-encode the `.p12` for **`MACOS_CERTIFICATE`**:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy   # now paste into MACOS_CERTIFICATE
   ```

#### `NOTARY_TEAM_ID`

Your 10-character Team ID — the code in parentheses at the end of the identity
name above (`A1B2C3D4E5`), also shown under **Membership details** at
developer.apple.com.

#### `NOTARY_APPLE_ID`

The email address of the Apple ID enrolled in the Developer Program.

#### `NOTARY_PASSWORD`

An **app-specific password**, *not* your real Apple ID password. At
[account.apple.com](https://account.apple.com) → **Sign-In and Security →
App-Specific Passwords**, click **+**, name it (e.g. `spindle-notary`), and copy
the generated `xxxx-xxxx-xxxx-xxxx` string.

Keep the `.p12` and the app-specific password in GitHub Secrets only — never
commit them.

## Building locally

The workflow just runs the same scripts you can run by hand:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/make-app.sh release
Scripts/notarize.sh                 # uses a `spindle-notary` keychain profile…
NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=TEAMID NOTARY_PASSWORD=app-specific \
  Scripts/notarize.sh               # …or pass credentials via the environment
Scripts/make-dmg.sh                 # → dist/Spindle.dmg
```
