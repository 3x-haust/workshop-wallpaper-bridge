# Contributing

Thanks for helping improve Workshop Wallpaper Bridge.

This project is a macOS utility for locally playing supported Wallpaper Engine Workshop projects. It supports personally copied files and permits Workshop search/download for App ID `431960` through normal Steam authentication within the user's account permissions. Keep the existing SwiftUI library and playback paths. Do not add authentication or entitlement bypasses, DRM bypasses, Steam protocol emulation, asset redistribution, network collection of user assets, or silent changes to original folders. Normal SteamKit client use in the separate helper is permitted; downloading an item does not establish playback support or full engine compatibility. Wallpaper Engine runtime `assets` must still be supplied from the user's own installation, never downloaded or bundled by this project.

## Before You Start

1. Check existing issues and pull requests.
2. For behavior changes, open an issue first unless the fix is small and obvious.
3. Keep each pull request focused on one problem.
4. Include tests when behavior changes.

## Local Setup

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift 6 toolchain
- .NET 9 SDK when building the separate Steam helper (`net9.0`)
- Optional: `ffmpeg` for WebM, MKV, and AVI conversion paths

Run the app:

```bash
swift run WorkshopWallpaperBridge
```

Run tests:

```bash
swift test
```

Build a local app bundle:

```bash
bash Scripts/package-app.sh
```

### Steam Helper

The Steam integration uses a separate GPL helper based on [SteamRE/DepotDownloader 3.4.0](https://github.com/SteamRE/DepotDownloader/tree/DepotDownloader_3.4.0), using SteamKit for normal authenticated access. Build it with:

```bash
bash Scripts/build-steam-helper.sh
bash Scripts/package-app.sh
```

The packaging target is a self-contained macOS arm64 helper bundled with the app, including its license and corresponding-source notices. Consumers should not install .NET or configure a CLI. Do not present build output alone as proof of working authentication, downloads, or playback.

Authentication persists in `~/Library/Application Support/WorkshopWallpaperBridge/Steam/credentials.json` (directory `0700`, file `0600`), not Keychain. Logout terminates the helper session but keeps the file. Deleting saved authentication removes only `credentials.json` and its interrupted atomic-save temporary file `credentials.json.tmp` in that directory. It does not affect authentication or sessions in the Steam app or other Steam clients and is not server-side token revocation. Cancelling a download terminates the helper/login; the UI offers reconnection with saved authentication.

Downloads stay under `~/Library/Application Support/WorkshopWallpaperBridge/WorkshopDownloads`; only completion-marked items appear as received. Importing an already-present item ID selects/links the existing library copy rather than overwriting it. The received-items list offers direct wallpaper application without requiring a switch to Library; additional conversion remains in Library.

## Commit Convention

Use short conventional commits:

```text
feat: add scene texture fallback
fix: prevent overlapping library imports
docs: add contribution guide
test: cover scanner symlink rejection
refactor: isolate library mutation workflow
perf: cache scene package entry lookup
chore: update release metadata
```

Allowed prefixes:

- `feat`: user-visible feature
- `fix`: bug fix
- `docs`: documentation only
- `test`: tests only
- `refactor`: code structure change without behavior change
- `perf`: performance improvement
- `chore`: maintenance, tooling, metadata
- `build`: build or packaging changes
- `ci`: CI changes
- `style`: formatting only
- `revert`: revert a previous commit

Why this exists: small conventional commit messages make release notes, review history, and rollback decisions easier.

## Pull Request Checklist

Before requesting review:

- [ ] The PR has one clear purpose.
- [ ] `swift test` passes locally.
- [ ] User-facing behavior is documented in `README.md` and `README.ko.md` when needed.
- [ ] New or changed behavior has tests.
- [ ] Library, Steam credential, and download writes stay within their designated app-owned directories; other writes require an explicit user-selected destination.
- [ ] Steam operations respect account permissions; credentials, tokens, and Guard codes never appear in logs or test fixtures.
- [ ] Credential permissions, logout/delete/cancel/reconnect, completion markers, and duplicate imports have focused checks.
- [ ] Packaged helper license/source notices are present; actual app-flow evidence and remaining unverified cases are reported separately from build/test success.
- [ ] Web wallpapers remain local and restricted.
- [ ] Scene support remains conservative; unsupported Wallpaper Engine runtime features are not presented as fully supported.
- [ ] No generated assets, screenshots, or local output files are committed unless they are intentionally part of the project.

## Review Expectations

Reviewers should look for:

- Race conditions in async app operations
- Manifest consistency in `LibraryStore`
- File path traversal or symlink escape risks
- Large file and decompression safety limits
- UI regressions around menu bar behavior and playback lifecycle
- Tests for supported and unsupported wallpaper formats

## AI-Assisted Contributions

AI tools are welcome, but the contributor is responsible for the final change.

If you use Copilot, Claude, Codex, or another assistant:

- Read the generated diff yourself before opening a PR.
- Do not submit changes you cannot explain.
- Run the test suite yourself.
- Mention AI assistance in the PR body when it materially shaped the change.
- Prefer small PRs so reviewers can verify behavior without trusting the tool.

Why this exists: AI tools are useful for speed, but this app touches local files, macOS app lifecycle behavior, and user-owned wallpaper assets. Human review must remain the source of truth.

## Reporting Security Issues

Please do not open a public issue for a suspected security vulnerability. See [SECURITY.md](SECURITY.md) for the private-reporting guidance.

Examples of security-sensitive issues:

- Deleting or modifying files outside the designated app-owned library, Steam credential, and download directories
- Leaking persistent Steam authentication or affecting unrelated Steam sessions
- Loading remote content from a local web wallpaper
- Path traversal from Workshop metadata or scene package entries
- Executing untrusted scripts outside the restricted WebView boundary
