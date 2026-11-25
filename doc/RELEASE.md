# Release Guide (Decaid Lab)

This document describes how to create releases for the **Decaid Lab** fork.

## Overview

Decaid Lab is a canary fork of upstream Decaid. Releases are artifact-only:
no Apple Developer ID / notarization, no TestFlight upload, and no Sparkle
auto-update feed. Android APKs are signed in CI; every artifact is published to
the `ChampionDesigns/Decaid-Lab` GitHub Release for manual download.

Signing exceptions:

- **Android:** `android/app/canary-release.keystore` is private and kept out of
  the repository. CI restores it from GitHub Actions secrets and signs release
  builds so the in-app auto-updater can install them. Keep a private backup; if
  the keystore is lost, existing installs can no longer be auto-updated.
- **macOS:** builds use Xcode's default ad-hoc signature only. No Developer ID,
  no notarization, no stapling. Users must right-click > Open the first time.
- **iOS:** the IPA is unsigned and must be signed with a profile of the user's
  choice before installation. There is no TestFlight/App Store upload.
- **Windows/Linux:** unsigned.

## Creating a Release

Decaid Lab uses git tags to trigger automatic releases. When you push a tag,
GitHub Actions will:

1. Build all supported platforms (Android signed; other platforms unsigned)
2. Package the macOS ZIP + DMG, Linux tarballs + AppImages, and the VC++-runtime
   bundle in the Windows ZIP
3. Generate release notes from merged pull requests using GitHub's release-notes
   generator
4. Attach every artifact plus a SHA-256 checksum manifest to a GitHub release

## Desktop Artifacts

Each tagged release attaches these files:

| Platform | Artifact | Install |
| --- | --- | --- |
| macOS (Intel + Apple Silicon) | `decaid-lab-macos-<version>.dmg` | Open the DMG and drag Decaid Lab to Applications. Unsigned; right-click > Open on first launch. |
| macOS (portable) | `decaid-lab-macos-<version>.zip` | Extract and run `Decaid Lab.app`. |
| Windows x64 | `decaid-lab-windows-x64-<version>.zip` | Extract the whole ZIP and run `Decaid-Lab.exe`. Portable and unsigned; the VC++ runtime is bundled. |
| Linux x86_64 | `decaid-lab-linux-x86_64-<version>.AppImage` | `chmod +x` and run. No installation needed. |
| Linux ARM64 | `decaid-lab-linux-aarch64-<version>.AppImage` | `chmod +x` and run. No installation needed. |
| Linux portable | `decaid-lab-linux-x64-<version>.tar.gz`, `decaid-lab-linux-arm64-<version>.tar.gz` | Extract and run `decaid-canary` from the bundle directory. |
| Android | `decaid-lab-android-<version>.apk` | Install directly; it is signed with the canary key. |
| iOS | `decaid-lab-ios-unsigned-<version>.ipa` | Sign with your own provisioning profile before installing. |

All files are covered by `decaid-lab-<version>-SHA256SUMS.txt` in the release.

Every file also ships as a `-latest` alias (`decaid-lab-android-latest.apk`,
`decaid-lab-macos-latest.dmg`, `decaid-lab-linux-x86_64-latest.AppImage`, ...), so
`https://github.com/ChampionDesigns/Decaid-Lab/releases/latest/download/decaid-lab-macos-latest.zip`
always points at the newest stable release. The aliases are covered by
`decaid-lab-latest-SHA256SUMS.txt`.

### Verifying checksums

```bash
# macOS / Linux
curl -sL -O https://github.com/ChampionDesigns/Decaid-Lab/releases/download/v<version>/decaid-lab-<version>-SHA256SUMS.txt
shasum -a 256 -c decaid-lab-<version>-SHA256SUMS.txt --ignore-missing
# download every artifact into the same directory first, or use --ignore-missing
```

```powershell
# Windows PowerShell
curl.exe -L -O https://github.com/ChampionDesigns/Decaid-Lab/releases/download/v<version>/decaid-lab-<version>-SHA256SUMS.txt
Get-FileHash decaid-lab-windows-x64-<version>.zip -Algorithm SHA256
# compare the hash against the manifest entry
```

### AppImage notes

- Optional desktop integration (menu entry, icon) is handled by AppImageLauncher or `appimaged` when installed; the AppImage itself always runs standalone.
- On systems without FUSE, run `./decaid-lab-linux-<arch>-<version>.AppImage --appimage-extract-and-run` instead.
- Removal is deleting the file; the app stores its data under `~/.local/share` (or `$XDG_DATA_HOME`).

### Windows notes

The Windows build is unsigned, so a clean machine may show an unknown-publisher warning when `Decaid-Lab.exe` is first launched. There is no installer; the ZIP is portable. Decaid Lab stores user data and logs under `%APPDATA%\net.tadel\Decide`, not in the extraction folder, so deleting the extracted folder does not remove them.

### macOS notes

macOS builds are not signed with a Developer ID and not notarized. On first
launch, right-click the app (or DMG) and choose **Open**, then confirm. The
in-app "Check for updates" flow opens the Releases page for manual download;
there is no Sparkle auto-update in the canary fork. Decaid Lab.app keeps the bundle id of the earlier Decide.app, so both read the same data; delete Decide.app after you install Decaid Lab.app.

### Dry-run validation before tagging

`Create Release` also accepts `workflow_dispatch`, which builds every platform job and then stops: `create-release` is guarded by `if: github.event_name == 'push'`, so a dispatch never creates a release or uploads assets to one. This is the way to validate a change to the workflow itself, or a new action/runtime version, without cutting a tag.

Dispatch it on the branch that contains the workflow change and pass an optional `version` label (default `0.0.0-dryrun`) used only in the artifact filenames:

```bash
gh workflow run "Create Release" --ref <branch> -f version=0.0.0-dryrun
gh run watch "$(gh run list --workflow "Create Release" --limit 1 --json databaseId --jq '.[0].databaseId')"
```

The dry run exercises the build jobs, so it costs the same runner time as a real release. The tag push remains the only path that publishes.

## Step 1: Tag Your Release

```bash
# For a stable release
git tag v1.0.0
git push origin v1.0.0

# For a beta release (will be marked as pre-release)
git tag v1.0.0-beta.1
git push origin v1.0.0-beta.1

# For an alpha release (will be marked as pre-release)
git tag v1.0.0-alpha.1
git push origin v1.0.0-alpha.1
```

## Step 2: Monitor the Build

1. Go to https://github.com/ChampionDesigns/Decaid-Lab/actions
2. Watch the "Create Release" workflow
3. Wait for it to complete (usually 5-10 minutes)

## Step 3: Verify the Release

1. Go to https://github.com/ChampionDesigns/Decaid-Lab/releases
2. Your new release should appear with all platform artifacts attached
3. Download and test the relevant artifacts
4. On an Android or iOS device, run a bulk de1app import (a few hundred shots)
   and watch for dropped frames. The import parses on the UI isolate; host
   figures are in `test/import/de1app_parse_benchmark_test.dart`, but no device
   measurement has been taken. If frames drop, the parse loop is what to move
   to a worker isolate.

## Version Numbering

Decaid Lab follows [Semantic Versioning](https://semver.org/):

- **MAJOR.MINOR.PATCH** (e.g., `v1.2.3`)
  - **MAJOR**: Breaking changes or major new features
  - **MINOR**: New features, backwards compatible
  - **PATCH**: Bug fixes, backwards compatible

### Pre-release Versions

- **Beta**: `v1.0.0-beta.1` - Feature complete, testing phase
- **Alpha**: `v1.0.0-alpha.1` - Early testing, incomplete features
- **RC**: `v1.0.0-rc.1` - Release candidate, final testing

## Update Channels

The app's update system recognizes these channels:

- **Stable**: Only final releases (v1.0.0, v2.1.0, etc.)
- **Beta**: Pre-releases and beta tags (v1.0.0-beta.1, etc.)
- **Development**: All releases including alphas

Pre-releases are automatically detected by:
- Version suffix (beta, alpha, rc)
- GitHub's pre-release flag

Update checks query `ChampionDesigns/Decaid-Lab` releases. Android shows an
in-app download/install flow for canary-signed builds; all other platforms open
the Release page.

## Editing Release Notes

The workflow publishes GitHub's generated release notes. After the release is created, review them and edit the release when a shorter summary, screenshots, upgrade instructions, or corrections are needed.

## Workflow Files

- **`.github/workflows/release.yml`**: Builds and publishes releases on tag push
- **`.github/workflows/develop-builds.yml`**: Development builds on main branch

### Development Artifacts

Development builds use stable GitHub Actions artifact names, while the packaged filename includes the seven-character commit SHA:

| Platform | Actions artifact | Downloaded file |
| --- | --- | --- |
| Android | `decaid-lab-android-develop` | `decaid-lab-android-develop-<short-sha>.apk` |
| macOS | `decaid-lab-macos-develop` | `decaid-lab-macos-develop-<short-sha>.zip` |
| Linux x64 | `decaid-lab-linux-x64-develop` | `decaid-lab-linux-x64-develop-<short-sha>.tar.gz` |
| Linux ARM64 | `decaid-lab-linux-arm64-develop` | `decaid-lab-linux-arm64-develop-<short-sha>.tar.gz` |
| Windows x64 | `decaid-lab-windows-x64-develop` | `decaid-lab-windows-x64-develop-<short-sha>.zip` |
| iOS | `decaid-lab-ios-unsigned-develop` | `decaid-lab-ios-unsigned-develop-<short-sha>.ipa` |

## Distribution Signing

Android CI requires the `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, and
`ANDROID_KEY_PASSWORD` GitHub Actions secrets. There is no Apple certificate,
provisioning profile, TestFlight/App Store Connect credential, or Sparkle EdDSA
key in CI.
