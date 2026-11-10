# Security Policy

Workshop Wallpaper Bridge works with user-selected local files and authenticated Steam Workshop content for Wallpaper Engine (App ID `431960`). Please report security-sensitive problems privately when possible. Never include passwords, QR login payloads, Steam Guard codes, tokens, or credential files in public issues or diagnostic logs.

## What To Report Privately

Please use GitHub private vulnerability reporting if it is enabled, or contact the maintainer directly, for issues such as:

- The app deletes or modifies files outside its designated library, Steam credential, or download directories without explicit user action.
- Steam credentials or tokens leak through logs, helper communication, permissions, or unintended file access.
- Authentication operations affect the Steam app or unrelated sessions, or bypass account permissions.
- Incomplete downloads appear completed, or imports silently overwrite an existing library copy.
- Workshop metadata, symlinks, or scene package entries can escape the selected project directory.
- A local web wallpaper can load unexpected remote content or execute outside the restricted WebView boundary.
- Scene package parsing can trigger unsafe memory, decompression, or large-file behavior.
- The app exposes, uploads, or redistributes local creator assets.

## What Can Be A Public Issue

Public issues are fine for:

- Import failures
- Playback bugs
- Unsupported wallpaper features
- Conversion failures
- UI problems
- Documentation mistakes

## Steam Authentication And Storage

The Steam integration uses a separate GPL helper based on SteamRE/DepotDownloader 3.4.0 and normal SteamKit authentication. This policy describes the required storage and session boundaries, not a completed security audit.

- Authentication is persisted across app launches in `~/Library/Application Support/WorkshopWallpaperBridge/Steam/credentials.json`. The `Steam` directory must have mode `0700` and the credential file mode `0600`. This is a local file, not macOS Keychain storage; filesystem permissions do not protect it from other processes running as the same user. Treat the file and its backups as secrets.
- Logout ends the helper session but retains saved authentication for reconnection.
- Deleting saved authentication removes only `credentials.json` and its interrupted atomic-save temporary file `credentials.json.tmp` in the app-specific Steam directory. It does not affect authentication or sessions in the Steam app or other Steam clients, or revoke tokens on Steam's servers.
- Cancelling a download terminates the helper and disconnects its current login. Reconnection uses saved authentication when available.
- Downloads belong under `~/Library/Application Support/WorkshopWallpaperBridge/WorkshopDownloads`. Only items with a completion marker belong in the received-items list. Downloaded metadata, files, and symlinks remain untrusted.
- Adding an item whose ID is already in the library links/selects the existing copy; it must not automatically overwrite that copy.

## Project Boundary

Normal authenticated search/download for App ID `431960` is permitted only within the account's permissions. Security fixes must not introduce Steam authentication or entitlement bypasses, DRM bypasses, Steam protocol emulation, creator-asset redistribution, or silent changes to the original copied Workshop folder. Normal SteamKit client use in the separate helper is not prohibited protocol emulation. Playback remains local and conservatively supported: downloading successfully does not guarantee playback or official Wallpaper Engine compatibility. The project does not download or bundle Wallpaper Engine runtime `assets`.

