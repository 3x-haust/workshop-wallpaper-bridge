# CLAUDE.md

Claude and other AI assistants should follow `AGENTS.md` first.

This file exists because some tools look specifically for `CLAUDE.md`. To avoid duplicated or conflicting instructions, the canonical repository guidance lives in `AGENTS.md`.

Quick reminders:

- Preserve local imports, the SwiftUI library, and local playback. Steam Workshop search/download is permitted only for App ID `431960` through normal authentication within the account's permissions.
- Do not add authentication/DRM bypasses, Steam protocol emulation, asset redistribution, or silent source-folder modification. A separate normal SteamKit client helper is permitted.
- Follow `AGENTS.md` for persistent app-only credentials, logout/delete/cancel semantics, completed downloads, duplicate-library handling, and separate GPL helper packaging.
- A successful download does not establish playback support or full Wallpaper Engine compatibility; keep scene/runtime-assets limits and report unverified app flows honestly.
- Preserve file system safety around user-selected paths and package metadata.
- Run `swift test` before saying a code change is complete.
- Update both `README.md` and `README.ko.md` for user-facing behavior changes.
- Use the commit convention documented in `CONTRIBUTING.md`.
- Work like an open-source contributor: never publish directly from `main`; create a focused branch, commit with a Conventional Commit subject, push the branch, open a PR with test evidence, merge only after review/checks, then release from a `v<version>` tag.
- For patch releases, use the next semantic patch tag, push it after the PR is merged, and let `.github/workflows/release.yml` publish the DMG and checksum.
