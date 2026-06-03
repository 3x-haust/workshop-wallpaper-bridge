# Security Policy

Workshop Wallpaper Bridge works with local files selected by the user. Please report security-sensitive problems privately when possible.

## What To Report Privately

Please use GitHub private vulnerability reporting if it is enabled, or contact the maintainer directly, for issues such as:

- The app deletes or modifies files outside its local library.
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

## Project Boundary

Security fixes must preserve the local-only boundary. This project should not add Steam Workshop downloading, Steam authentication bypasses, DRM bypasses, or asset redistribution features.

