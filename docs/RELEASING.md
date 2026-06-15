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

### Exporting the certificate

1. In **Keychain Access**, find your *Developer ID Application* certificate,
   right-click it → **Export**, and save a `.p12` with a password.
2. Base64-encode it for the secret:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy   # now paste into MACOS_CERTIFICATE
   ```

3. Find the exact identity string for `MACOS_SIGN_IDENTITY`:

   ```sh
   security find-identity -v -p codesigning
   ```

## Building locally

The workflow just runs the same scripts you can run by hand:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/make-app.sh release
Scripts/notarize.sh                 # uses a `spindle-notary` keychain profile…
NOTARY_APPLE_ID=you@example.com NOTARY_TEAM_ID=TEAMID NOTARY_PASSWORD=app-specific \
  Scripts/notarize.sh               # …or pass credentials via the environment
Scripts/make-dmg.sh                 # → dist/Spindle.dmg
```
