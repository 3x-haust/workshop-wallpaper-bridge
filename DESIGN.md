# Wallpaper Browser

## Structure

The app is a native macOS browser for a private wallpaper library and authenticated Steam Workshop content. SwiftUI, AppKit, the system font and SF Symbols remain the UI stack.

- **Explore:** server-backed search and sorting; a filter sheet for age, type, genre, resolution and features; thumbnail grid; selected-item preview and details. Tags have neutral/include/exclude states. Everyone-only is the initial and reset age setting; filter choices persist.
- **My Wallpapers:** the local library, single-item application, multiple selection and existing conversion, display-mode and rotation controls.
- **Settings:** existing playback, audio, integration, permissions, assets and language controls.
- Steam account status and authentication are available at the bottom of the sidebar. Playback status and Stop remain in the bottom bar.

The default content size is 1180 × 760 points; the minimum is 640 × 560. The sidebar is 174 points wide, collapsing to a 64-point icon rail below 900 points. A 300-point inspector appears when the remaining content has enough room. Smaller windows expose the same details in a sheet, not by shrinking text or hiding actions.

## Visual language

`WallpaperBrowserComponents.swift` owns the shared colors and small reusable views.

| Role | Value |
| --- | --- |
| Main background | `#141619` |
| Sidebar and inspector | `#1B1D21` |
| Controls | `#202328` |
| Raised surface | `#282C32` |
| Dividers | `#30343A` |
| Main text | `#EFF1F4` |
| Secondary text | `#9CA3AE` |
| Accent | `#79ADFF` |
| Selected navigation | `#263B59` |

Use 25-point semibold screen headings, 20-point inspector titles, 12–13-point controls and 10–12-point secondary metadata. Main content gutters are 20–24 points. Thumbnails and controls have 6–7-point corners; selection uses a thin accent outline. Images carry the visual emphasis. Do not add decorative cards, gradients, new fonts or icon libraries.

Keep accessible names on icon-only navigation and buttons. Preserve keyboard activation, visible focus, multiple selection and readable text at the minimum window size. English and Korean UI strings belong in the existing localization tables.

## Interaction

Selecting a supported installed item requests immediate application. A new Workshop item uses **Download & Apply**: explicit download completion, storage validation, existing-copy linking or safe library import, support assessment, then playback. No extra Workshop import button is required. Local copied-folder imports retain their explicit selection and copy operation.

There is no separate Downloads tab. Explore shows download and preparation progress; My Wallpapers owns completed-item management. Removing a library item also removes its completed download and playback caches, without touching source files or account data.

Required scene rendering finishes before Download & Apply replaces the current wallpaper. Fresh render caches are reused. Shared renders may finish caching after cancellation, but cannot apply a cancelled selection.

The selected image is a preview, not proof that the project can play. Download completion, playback request and content readiness are distinct. Unsupported content remains available for inspection or conversion without stopping the current wallpaper. Preparing replacement windows must not discard working windows before the replacement is ready.

Use only real metadata and loaded files. Show empty, disconnected, loading, failure, unsupported and retry states rather than sample content. No creator artwork or Wallpaper Engine runtime assets are bundled for decoration.

## References

- [Wallpaper Engine in-app Workshop browser announcement](https://steamstore-a.akamaihd.net/news/externalpost/steam_community_announcements/75836429537697378): search, type/tags, sort, pagination and creator-provided preview video.
- [Wallpaper Engine discovery announcement](https://steamstore-a.akamaihd.net/news/externalpost/steam_community_announcements/2431262783620571352): genre, keyword and creator discovery.
- [Developer discussion of selection and application](https://steamcommunity.com/app/431960/discussions/0/3030299766084114308/): historical explanation of loading properties and applying a wallpaper.
- [Eagle](https://eagle.cool/): separation of navigation, image grid and inspector.
- [Wallper](https://www.wallper.app/): image-led wallpaper browsing with a small primary navigation surface.

The Wallpaper Engine screenshots referenced above are historical Windows UI, not evidence of current-version behavior. Download-completion auto-application is this app's interaction contract; it is not presented as a verified universal behavior of the original app.
