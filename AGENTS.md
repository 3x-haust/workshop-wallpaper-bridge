# AGENTS.md

Guidance for AI coding assistants working in this repository.

## Project Boundary

Workshop Wallpaper Bridge is a macOS utility for importing Wallpaper Engine Workshop projects into a private Mac library and playing supported content locally. It preserves copied-folder imports and permits Workshop search and downloads for Wallpaper Engine (App ID `431960`) through normal Steam authentication, only within the signed-in account's permissions.

Do not implement:

- Steam authentication or account-entitlement bypass
- DRM bypass
- Steam protocol emulation or impersonation; normal authenticated SteamKit client use in the separate helper is permitted and is not this prohibited behavior
- Uploading, sharing, or redistributing creator assets
- Silent modification of the original copied Workshop folder
- Downloads or bundling of Wallpaper Engine runtime `assets`

The existing SwiftUI library and playback paths remain in place. The Workshop tab covers QR or account/Steam Guard login, search/details, download progress/cancel/retry, completed downloads, library import, and direct wallpaper application from received items without requiring a switch to Library. Additional conversion remains in Library. A successful download is not evidence of successful playback or official engine compatibility; preserve the existing conservative scene support limits.

Steam integration contracts:

- Use a separate GPL helper based on SteamRE/DepotDownloader 3.4.0. `Scripts/build-steam-helper.sh` builds the self-contained macOS arm64 helper for integration by `Scripts/package-app.sh`; consumers must not need .NET installation or CLI setup. Developers need the .NET 9 SDK to build the helper (`net9.0`).
- Persist app-specific authentication in `~/Library/Application Support/WorkshopWallpaperBridge/Steam/credentials.json`, with directory mode `0700` and file mode `0600`. This is file-based persistent storage, not Keychain storage. Never log credentials, tokens, or Guard codes.
- Logout ends the helper session but retains saved authentication. Deleting saved authentication removes only `credentials.json` and its interrupted atomic-save temporary file `credentials.json.tmp` in the app-specific Steam directory. It does not affect authentication or sessions in the Steam app or other Steam clients, or revoke tokens on Steam's servers.
- Download to `~/Library/Application Support/WorkshopWallpaperBridge/WorkshopDownloads`. Only items with a completion marker enter the completed-download list.
- If an item ID already exists in the Mac library, link/select the existing copy; never silently overwrite it.
- Cancelling a download terminates the helper and disconnects its current login. Offer reconnection using saved authentication.
- Do not describe the new end-to-end app flow as verified without actual app evidence.

Why this exists: the project is a bridge for content the user is entitled to access, not a replacement for Wallpaper Engine or Steam.

## Development Commands

Use these commands before claiming a change is complete:

```bash
swift test
```

For app bundle changes:

```bash
bash Scripts/package-app.sh
```

For CLI behavior:

```bash
swift run wwbctl doctor
```

## Code Style

- Prefer small, direct Swift types over broad abstractions.
- Keep file system safety explicit.
- Treat user-selected paths, Workshop metadata paths, scene package paths, and symlinks as untrusted.
- Keep UI state changes on the main actor.
- Do not move file I/O or conversion work to background tasks without also handling reentrancy, cancellation, and manifest consistency.
- Preserve the conservative scene support boundary.

## Architecture Notes

- `WorkshopWallpaperCore` owns scanning, package parsing, library storage, conversion helpers, and shared models.
- `WorkshopWallpaperBridgeApp` owns SwiftUI/AppKit UI, menu bar lifecycle, playback windows, and macOS integration.
- `wwbctl` is a CLI surface for testing and advanced users.
- `LibraryStore` writes the local Mac library manifest and copied assets. Treat manifest mutations as consistency-sensitive.

## Review Checklist For AI Agents

Before proposing or committing changes, check:

- Does `swift test` pass?
- Are new async operations protected from overlapping writes or stale UI updates?
- Are paths normalized and constrained before reading or writing, including helper output, downloads, and credentials?
- Are persistent credentials private, completion markers trustworthy, and logout/delete/cancel semantics accurately reflected in the UI?
- Are separate GPL helper source/license notices included when distributing it?
- Are large package, texture, and decompression limits preserved?
- Are unsupported Wallpaper Engine runtime features still described honestly?
- Did README changes update both English and Korean docs when user-facing behavior changed?

## Open Source Workflow For AI Agents

Treat this repository like a public open-source project, even for local agent work.

- Never publish work directly from `main`. Create a focused branch before committing, pushing, opening a PR, or preparing a release.
- Do not commit directly to `main` unless the user explicitly asks for a direct hotfix.
- Create a focused branch before publishing changes, for example `fix/dock-flicker` or `docs/contribution-workflow`.
- Keep each branch and pull request scoped to one problem.
- Use Conventional Commit messages from this file.
- Before opening a PR, run the required local checks for the touched surface:
  - `swift test` for code changes.
  - `bash Scripts/package-app.sh` for app bundle or release changes.
  - `swift run wwbctl doctor` for CLI behavior changes.
- Open a GitHub pull request with a short summary, test evidence, and any AI assistance note when an assistant materially shaped the change.
- Do not merge a PR until the local checks are green and the diff has been reviewed.
- Release only from a tag created after the reviewed PR has landed on `main`; do not tag or release an unreviewed feature branch unless the user explicitly requests a prerelease.

## Patch And Release Workflow

When preparing a patch release:

1. Start from an up-to-date `main`.
2. Create a branch named for the fix, such as `fix/<issue-slug>`.
3. Make the smallest behavior-preserving patch that solves the issue.
4. Add or update regression tests before the production fix when behavior changes.
5. Run `swift test` and, for app releases, `bash Scripts/package-app.sh`.
6. Commit with a `fix:` subject for bug fixes.
7. Push the branch and open a PR.
8. Merge the PR into `main`.
9. Tag the merged commit with the next semantic version:
   - Patch bug fix: `vMAJOR.MINOR.PATCH`
   - Feature release: `vMAJOR.MINOR.0`
10. Push the tag. The release workflow builds the DMG, checksum, and GitHub Release.

Release tags must use the `v<version>` format because `.github/workflows/release.yml` derives the app version from the tag.

## Commit Messages

Use this convention:

```text
feat: 내용
fix: 내용
docs: 내용
refactor: 내용
test: 내용
chore: 내용
build: 내용
ci: 내용
perf: 내용
style: 내용
revert: 내용
```

Why this exists: consistent commits make open-source review and release history easier to scan.
