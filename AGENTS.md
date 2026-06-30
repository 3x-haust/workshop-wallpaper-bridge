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

## Open Source Workflow For AI Agents

Treat this repository like a public open-source project, even for local agent work.

- For maintainer, deploy, release, CI/CD, verification, and project-channel requests, use the `$work` workflow so repository work is grounded in the LLM Wiki when it is available.
- Keep `VAULT_ROOT` and `REPO_ROOT` separate. Resolve wiki memory in this order: `$LLM_WIKI_ROOT` when set, `/workspace/llm-wiki`, then a repo-local `wiki/` only when it exists. Do not fail a deploy or maintainer task merely because this repository has no `wiki/` directory; if no wiki is found, name the searched paths and continue from repository files, GitHub state, and explicit user context.
- Never publish work directly from `main`. Create a focused branch before committing, pushing, opening a PR, preparing a release, or deploying.
- Do not commit directly to `main` unless the user explicitly asks for a direct hotfix.
- Create a focused branch before publishing changes, for example `fix/dock-flicker` or `docs/contribution-workflow`.
- Keep each branch and pull request scoped to one problem.
- Use Conventional Commit messages from this file.
- Maintainer changes must follow this order: update `main`, create the matching branch, make and verify the change, push the branch, open a PR, merge the PR after checks/review, then delete the completed branch.
- Delete completed branches after merge. Use `Scripts/cleanup-merged-branches.sh origin main` to prune local and remote branches already merged into `origin/main`; the script skips `main`, the current branch, unmerged branches, and branches checked out in another worktree.
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
9. Delete the completed branch locally and on GitHub, or run `Scripts/cleanup-merged-branches.sh origin main`.
10. Tag the merged commit with the next semantic version:
   - Patch bug fix: `vMAJOR.MINOR.PATCH`
   - Feature release: `vMAJOR.MINOR.0`
11. Push the tag. The release workflow builds the DMG, checksum, and GitHub Release.

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
