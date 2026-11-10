# Workshop Wallpaper Bridge — Steam helper

This is a **separate GPL-2.0 component**, derived from SteamRE's DepotDownloader
3.4.0. The Swift app launches it as a process and communicates through newline
JSON. No Steam credentials or creator assets are shipped with this component.

## Source provenance

- Upstream: https://github.com/SteamRE/DepotDownloader
- Tag: `DepotDownloader_3.4.0`
- Commit: `c553ef4d60c00a4f5fd16c9fe017f569001589ff`
- Archive SHA-256: `2f09a0aaf003ee01fce44ec9acc0371441172e27d544eb7ccbe7974c01f47f42`
- Upstream license: `LICENSE` (GNU GPL version 2).
- Original source: `upstream/DepotDownloader_3.4.0.tar.gz`.
- Modified upstream source: `DepotDownloader/`; reproducible changes:
  `patches/bridge.patch`. `verify-source.py` verifies both the archive hash and
  that applying the patch recreates these files exactly.
- Original authors: SteamRE Team. Bridge modifications are distributed under
  GPL-2.0; see the accompanying source archive for the modified implementation.

`steam-helper-source.tar.gz` in the binary distribution contains this helper's
source, the original upstream archive, patch, lockfile, native shim and build
scripts. `Licenses/` contains upstream and dependency license notices and a
`dependencies.json` manifest with source repositories and versions. SteamKit2
3.2.0 is LGPL-2.1-only and is shipped as a separate DLL; its source is available
at https://github.com/SteamRE/SteamKit/tree/3.2.0 . Rebuilding against a modified
SteamKit2 is supported by changing the project dependency/lockfile. The .NET
runtime notices are included separately. Preserve these materials when
redistributing the helper.

## Bridge-specific changes

- Replaces terminal UI with a single persistent stdin/stdout JSON process.
  The original terminal entry point is retained as source but excluded from
  compilation. All original console output and diagnostic logging are disabled.
- Uses SteamKit authentication, Unified PublishedFile search/details, and
  DepotDownloader's existing CDN manifest/chunk/download algorithm. App ID is
  fixed to 431960. Access refusals are errors, never bypassed.
- Credentials use only the explicit app-owned `credentials.json`, with a 0700
  directory, atomic 0600 file creation/replacement, and surfaced storage errors.
  Authentication directory creation and download-root opening reject symlinks
  in every parent component using descriptor-relative traversal from `/`.
- A disconnected session becomes logged out and cancels authentication. An
  authentication attempt starts once; reconnect callbacks cannot duplicate QR
  polling or reuse a canceled session. A new login request creates a new session
  instead of silently reconnecting. Live QR reconnection behavior is not claimed
  to have been validated against Steam; concurrent/canceled attempts are covered
  by account-free tests.
- All download writes, creates, deletes, moves and permission changes use
  descriptor-relative macOS I/O with no-follow traversal. Absolute, traversal,
  backslash, empty, reserved metadata, link and replaced-root paths are rejected.
  The native shim fixes Darwin arm64 variadic `open/openat` ABI differences.
- Completion requires all downloaded manifest files to match their lengths and
  SHA-1 hashes. HTTP-based Workshop files are verified against Steam's reported
  size over HTTPS (PublishedFile metadata does not provide their file hash).
  Missing manifests, depot access, missing files and integrity failures cannot
  produce a completion event.

## Build and test

On macOS arm64 with Xcode Command Line Tools:

```bash
bash Scripts/build-steam-helper.sh
# Use the pinned SDK selected/installed by the build script:
cd SteamHelper
/path/to/dotnet run --project tests/SteamHelper.Tests.csproj
python3 tests/ipc-test.py ../.build/steam-helper/wwb-steam-helper
```

`DOTNET_ROOT` may identify an existing SDK 9.0.320. Otherwise the build script
installs the official, SHA-512-verified SDK into `APP_SCRATCH_DIR` (or a temporary
build cache outside the repository). NuGet dependencies use locked restore.
The published folder is self-contained: users do not install .NET or run a CLI.
Package **all of `.build/steam-helper/`**, not just its apphost executable, and
preserve executable permissions. App packaging/signing is performed separately.
Do not trim or AOT the helper without validating protobuf/reflection behavior.

## IPC

Launch: `wwb-steam-helper --data-directory <absolute app auth directory>`.
Credentials must never be provided through arguments or environment variables.
Input: one JSON object per line with UUID `id` and `command`. Commands are
`loginQR`, `loginPassword` (`username`, `password`), `guard` (`code`, same login
ID), `resume`, `search` (`query`, one-based `page`), `details` (`itemID`) and
`download` (`itemID`, an existing empty `directory`). One request at a time;
guard is the only additional request during authentication. Logout/cancel means
terminating the helper and clearing app state. Logout retains saved credentials;
only the separate delete-saved-authentication action removes `credentials.json`
and `credentials.json.tmp`.

Output: one JSON object per line, repeating `id`; `type` is `qr`, `authPrompt`,
`authenticated`, `items`, `detail`, `progress`, `completed`, `disconnected`, or
`error`. `items` includes `page`, `pageSize` (the server request size, including
filtered-out entries), and `total`. An unsolicited `disconnected` event clears
login state even when no request is pending.
`authenticated/items/detail/completed/error` terminate a request. QR URLs,
passwords, guard codes and refresh tokens are sensitive and must not be logged.
Only successful authentication reveals the account name. Error messages and
guard explanations are static; Steam exceptions and email addresses are never
forwarded. Failed `resume` terminates with an error, allowing a fresh login.

Tests use temporary fixtures only, with no account, network or existing auth
store. Real authentication, search, permissions and content delivery still need
an explicitly authorized integration check in the packaged Swift app.
