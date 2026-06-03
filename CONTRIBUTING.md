# Contributing

Thanks for helping improve Workshop Wallpaper Bridge.

This project is a local-only macOS utility for playing personally copied Wallpaper Engine Workshop projects. Contributions should keep that boundary clear: do not add Steam authentication bypasses, Workshop downloading, DRM bypasses, asset redistribution, or network collection of user assets.

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
- [ ] File system writes stay inside the Mac library unless the user explicitly chose a source file/folder.
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

- Deleting or modifying files outside the app library
- Loading remote content from a local web wallpaper
- Path traversal from Workshop metadata or scene package entries
- Executing untrusted scripts outside the restricted WebView boundary
