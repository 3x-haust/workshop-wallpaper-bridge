# AGENTS.md

Guidance for AI coding assistants working in this repository.

## Project Boundary

Workshop Wallpaper Bridge is a local-only macOS utility. It scans a user-copied Wallpaper Engine Workshop folder, imports supported projects into a private Mac library, and plays supported wallpaper content locally.

Do not implement:

- Steam Workshop downloading
- Steam authentication bypass
- DRM bypass
- Steam protocol emulation
- Uploading, sharing, or redistributing creator assets
- Silent modification of the original copied Workshop folder

Why this exists: the project is intentionally framed as a local bridge for assets the user already has access to, not as a replacement for Wallpaper Engine or Steam.

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
- Are paths normalized and constrained before reading or writing?
- Are large package, texture, and decompression limits preserved?
- Are unsupported Wallpaper Engine runtime features still described honestly?
- Did README changes update both English and Korean docs when user-facing behavior changed?

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

