# Release Guide (Decaid-Canary)

This document describes how to create releases for the **Decaid-Canary** fork.

## Overview

Decaid-Canary is a canary fork of upstream Decaid. Releases are **unsigned,
artifact-only**: no Apple Developer ID / notarization, no TestFlight upload, no
Android distribution keystore in CI, and no Sparkle auto-update feed. Every
artifact is published to the `ChampionDesigns/Decaid-Canary` GitHub Release for
manual download.

Signing exceptions:

- **Android (local builds only):** `android/app/canary-release.keystore` is a
  private keystore kept out of the repository. When it exists, local release
  builds are signed with it so the in-app auto-updater can install them. CI has
  no keystore and emits `app-release-unsigned.apk`. Keep a backup of the
  keystore; if it is lost, existing installs can no longer be auto-updated.
- **macOS:** builds use Xcode's default ad-hoc signature only. No Developer ID,
  no notarization, no stapling. Users must right-click > Open the first time.
- **iOS:** the IPA is unsigned and must be signed with a profile of the user's
  choice before installation. There is no TestFlight/App Store upload.
- **Windows/Linux:** unsigned.

## Creating a Release

Decaid-Canary uses git tags to trigger automatic releases. When you push a tag,
GitHub Actions will:

1. Build all supported platforms (unsigned)
2. Package the macOS ZIP + DMG, Linux tarballs + AppImages, and the VC++-runtime
   bundle in the Windows ZIP
3. Generate release notes from merged pull requests using GitHub's release-notes
   generator
4. Attach every artifact plus a SHA-256 checksum manifest to a GitHub release

## Desktop Artifacts

Each tagged release attaches these files:

| Platform | Artifact | Install |
| --- | --- | --- |
| macOS (Intel + Apple Silicon) | `decaid-canary-macos-<version>.dmg` | Open the DMG and drag Decaid-Canary to Applications. Unsigned; right-click > Open on first launch. |
| macOS (portable) | `decaid-canary-macos-<version>.zip` | Extract and run `Decaid-Canary.app`. |
| Windows x64 | `decaid-canary-windows-x64-<version>.zip` | Extract the whole ZIP and run `Decaid-Canary.exe`. Portable and unsigned; the VC++ runtime is bundled. |
| Linux x86_64 | `decaid-canary-linux-x86_64-<version>.AppImage` | `chmod +x` and run. No installation needed. |
| Linux ARM64 | `decaid-canary-linux-aarch64-<version>.AppImage` | `chmod +x` and run. No installation needed. |
| Linux portable | `decaid-canary-linux-x64-<version>.tar.gz`, `decaid-canary-linux-arm64-<version>.tar.gz` | Extract and run `decaid-canary` from the bundle directory. |
| Android | `decaid-canary-android-<version>-unsigned.apk` | Sign with a key of your choice before installing (CI build); local canary-signed builds are named `app-release.apk`. |
| iOS | `decaid-canary-ios-unsigned-<version>.ipa` | Sign with your own provisioning profile before installing. |

All files are covered by `decaid-canary-<version>-SHA256SUMS.txt` in the release.

Every file also ships as a `-latest` alias (`decaid-canary-android-latest-unsigned.apk`,
`decaid-canary-macos-latest.dmg`, `decaid-canary-linux-x86_64-latest.AppImage`, ...), so
`https://github.com/ChampionDesigns/Decaid-Canary/releases/latest/download/decaid-canary-macos-latest.zip`
always points at the newest stable release. The aliases are covered by
`decaid-canary-latest-SHA256SUMS.txt`.

### Verifying checksums

```bash
# macOS / Linux
curl -sL -O https://github.com/ChampionDesigns/Decaid-Canary/releases/download/v<version>/decaid-canary-<version>-SHA256SUMS.txt
shasum -a 256 -c decaid-canary-<version>-SHA256SUMS.txt --ignore-missing
# download every artifact into the same directory first, or use --ignore-missing
```

```powershell
# Windows PowerShell
curl.exe -L -O https://github.com/ChampionDesigns/Decaid-Canary/releases/download/v<version>/decaid-canary-<version>-SHA256SUMS.txt
Get-FileHash decaid-canary-windows-x64-<version>.zip -Algorithm SHA256
# compare the hash against the manifest entry
```

### AppImage notes

- Optional desktop integration (menu entry, icon) is handled by AppImageLauncher or `appimaged` when installed; the AppImage itself always runs standalone.
- On systems without FUSE, run `./decaid-canary-linux-<arch>-<version>.AppImage --appimage-extract-and-run` instead.
- Removal is deleting the file; the app stores its data under `~/.local/share` (or `$XDG_DATA_HOME`).

### Windows notes

The Windows build is unsigned, so a clean machine may show an unknown-publisher warning when `Decaid-Canary.exe` is first launched. There is no installer; the ZIP is portable. Decaid-Canary stores user data and logs under `%APPDATA%`, not in the extraction folder, so deleting the extracted folder does not remove them.

### macOS notes

macOS builds are not signed with a Developer ID and not notarized. On first
launch, right-click the app (or DMG) and choose **Open**, then confirm. The
in-app "Check for updates" flow opens the Releases page for manual download;
there is no Sparkle auto-update in the canary fork.

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

1. Go to https://github.com/ChampionDesigns/Decaid-Canary/actions
2. Watch the "Create Release" workflow
3. Wait for it to complete (usually 5-10 minutes)

## Step 3: Verify the Release

1. Go to https://github.com/ChampionDesigns/Decaid-Canary/releases
2. Your new release should appear with all platform artifacts attached
3. Download and test the relevant artifacts

## Version Numbering

Decaid-Canary follows [Semantic Versioning](https://semver.org/):

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

Update checks query `ChampionDesigns/Decaid-Canary` releases. Android shows an
in-app download/install flow for builds signed with the canary keystore; all
other platforms (and unsigned APKs) open the Release page.

## Editing Release Notes

The workflow publishes GitHub's generated release notes. After the release is created, review them and edit the release when a shorter summary, screenshots, upgrade instructions, or corrections are needed.

## Workflow Files

- **`.github/workflows/release.yml`**: Builds and publishes releases on tag push
- **`.github/workflows/develop-builds.yml`**: Development builds on main branch

### Development Artifacts

Development builds use stable GitHub Actions artifact names, while the packaged filename includes the seven-character commit SHA:

| Platform | Actions artifact | Downloaded file |
| --- | --- | --- |
| Android | `decaid-canary-android-develop` | `decaid-canary-android-develop-<short-sha>.apk` |
| macOS | `decaid-canary-macos-develop` | `decaid-canary-macos-develop-<short-sha>.zip` |
| Linux x64 | `decaid-canary-linux-x64-develop` | `decaid-canary-linux-x64-develop-<short-sha>.tar.gz` |
| Linux ARM64 | `decaid-canary-linux-arm64-develop` | `decaid-canary-linux-arm64-develop-<short-sha>.tar.gz` |
| Windows x64 | `decaid-canary-windows-x64-develop` | `decaid-canary-windows-x64-develop-<short-sha>.zip` |
| iOS | `decaid-canary-ios-unsigned-develop` | `decaid-canary-ios-unsigned-develop-<short-sha>.ipa` |

## No Distribution Signing

Decaid-Canary deliberately has no CI signing secrets. The workflows use only the
automatically provided `GITHUB_TOKEN` (required for checkout, dependency
downloads, and the GitHub Release API). There is no Apple certificate, no
provisioning profile, no Android keystore, no TestFlight/App Store Connect
credentials, and no Sparkle EdDSA key in CI.
