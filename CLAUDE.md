# CLAUDE.md

Claude and other AI assistants should follow `AGENTS.md` first.

This file exists because some tools look specifically for `CLAUDE.md`. To avoid duplicated or conflicting instructions, the canonical repository guidance lives in `AGENTS.md`.

Quick reminders:

- Keep the app local-only.
- Do not add Steam, DRM, or asset redistribution bypass behavior.
- Preserve file system safety around user-selected paths and package metadata.
- Run `swift test` before saying a code change is complete.
- Update both `README.md` and `README.ko.md` for user-facing behavior changes.
- Use the commit convention documented in `CONTRIBUTING.md`.
- Work like an open-source contributor: use `$work` for maintainer/deploy/release requests, never publish directly from `main`; create a focused branch, commit with a Conventional Commit subject, push the branch, open a PR with test evidence, merge only after review/checks, delete the completed branch, then release from a `v<version>` tag.
- Resolve LLM Wiki memory from `$LLM_WIKI_ROOT`, `/workspace/llm-wiki`, then repo-local `wiki/`; do not treat this repo's missing `wiki/` directory as a deploy blocker.
- For patch releases, use the next semantic patch tag, push it after the PR is merged, and let `.github/workflows/release.yml` publish the DMG and checksum.
