# Open Source Maintenance Notes

This document explains why the repository includes each contribution file and how maintainers should use it.

## `CONTRIBUTING.md`

Purpose: give contributors one place to learn setup, tests, commit convention, PR expectations, and AI-assisted contribution rules.

Reasoning: this project is easy to misunderstand as a Steam or Wallpaper Engine replacement. The contribution guide repeats the local-only boundary so feature proposals and PRs stay reviewable.

## `AGENTS.md`

Purpose: give Codex, Copilot-style agents, and other AI coding tools repo-specific rules.

Reasoning: AI tools often optimize for implementation speed. This project needs extra care around file system safety, Swift concurrency, and honest compatibility claims. `AGENTS.md` makes those constraints explicit.

## `CLAUDE.md`

Purpose: support tools that specifically look for a Claude instruction file.

Reasoning: duplicating full instructions across many AI files creates drift. `CLAUDE.md` points back to `AGENTS.md` and keeps only short reminders.

## `.github/copilot-instructions.md`

Purpose: guide GitHub Copilot review and code suggestions.

Reasoning: Copilot can catch useful issues, especially around async regressions, when it knows the project boundaries and test layout.

## `.github/PULL_REQUEST_TEMPLATE.md`

Purpose: make every PR state its scope, validation, safety checks, and AI assistance status.

Reasoning: reviewers should not have to guess whether tests ran, whether docs were updated, or whether a change risks unsupported Steam/DRM behavior.

## Issue Templates

Purpose: route reports into bug, compatibility, and feature request flows.

Reasoning:

- Bug reports need reproduction steps, macOS version, app version, and logs.
- Compatibility reports need wallpaper type and safe metadata without encouraging asset redistribution.
- Feature requests need an explicit project-boundary check.

## `SECURITY.md`

Purpose: separate private security reports from normal public issues.

Reasoning: this app reads user-selected folders, parses third-party package formats, and renders local web content. Vulnerabilities in those areas should not be debugged first in a public issue thread.

## Commit Convention

Purpose: keep history readable.

Reasoning: conventional prefixes such as `fix`, `feat`, `docs`, `test`, and `perf` make release notes and future archaeology easier, especially when outside contributors and AI-generated commits are involved.
