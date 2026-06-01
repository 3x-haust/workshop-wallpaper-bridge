# Finish Workshop Wallpaper Bridge v0.2.1

## TL;DR
> Summary:      Finish the current dirty v0.2.1 work by making the settings window reliably appear centered on launch, adding a section-2 library delete flow, preserving local-only import behavior, and proving the app/package has no obvious launch/runtime errors.
> Deliverables:
> - Centered launch settings window with focused regression tests
> - Safe delete flow for imported Mac library items from section 2
> - Preserved Add Video File and `wwbctl import-video` behavior
> - Menu-bar app package with `LSUIElement=true`
> - Agent-captured test, package, CLI, and GUI QA evidence
> Effort:       Medium
> Risk:         Medium - SwiftUI menu-bar app launch/activation and AppKit window placement require real macOS GUI verification, not only unit tests.

## Scope
### Must have
- Settings window appears when the app launches and is centered on the active/main usable screen.
- Reopening settings from the menu bar reuses the same settings window and keeps it visible/focused.
- Section 2 / "Play from your Mac library" exposes a delete/remove control for selected imported library items.
- Deleting a Mac library item removes only the app-managed imported copy and manifest entry, not the original source video or copied Workshop folder.
- Add Video File still imports MP4/MOV/M4V as playable and WebM/MKV/AVI as needing conversion.
- `wwbctl import-video <video-file> [--library <folder>]` still works and fails cleanly on unsupported files.
- Packaged app remains a menu-bar utility with `LSUIElement=true`.
- TDD evidence exists for the centered-window helper and library deletion behavior.
- Real macOS GUI QA evidence exists for launch, import, delete, and no visible error dialogs.
- Swift files touched by the finish pass stay under 250 pure LOC; if a file would exceed that, split along an existing local boundary.

### Must NOT have (guardrails, anti-slop, scope boundaries)
- Do not add Steam Workshop downloading, Steam auth, DRM bypass, Steam protocol emulation, upload/sharing, or `scene.pkg` unpacking; the README local-only guardrails already state this at `README.md:61` and `README.md:65`.
- Do not use private macOS APIs or patch system wallpaper databases; current docs explicitly avoid that at `README.md:38`.
- Do not modify original Workshop folders or original manually selected videos; imported copies live under `~/Library/Application Support/WorkshopWallpaperBridge` as documented at `README.md:73`.
- Do not delete or rewrite unrelated dirty files or `.omo/` runtime artifacts.
- Do not broaden this into a design refresh, updater, notarization flow, or dependency addition.
- Do not suppress Swift errors with unsafe casts, `@ts-ignore`-style equivalents, or ignored failing tests.

## Verification strategy
> Zero human intervention - all verification is agent-executed.
- Test decision: TDD + XCTest via SwiftPM
- QA policy: every task has agent-executed scenarios
- Evidence: `evidence/task-<N>-<slug>.<ext>`

## Execution strategy
### Parallel execution waves
> Target 5-8 tasks per wave. <3 per wave (except final) = under-splitting.
> Extract shared dependencies as Wave-1 tasks to maximize parallelism.

Wave 1 (no dependencies):
- Task 1: implement/test deterministic settings-window placement
- Task 2: harden/test core library deletion safety
- Task 3: preserve/test manual video import and CLI import-video
- Task 4: verify/update package and docs menu-bar/local-only contract
- Task 5: enforce dirty-tree hygiene and Swift file-size constraints

Wave 2 (after Wave 1):
- Task 6: depends [2, 5] - add/test AppViewModel deletion action and playback state
- Task 7: depends [6] - wire/test section-2 delete UI control
- Task 8: depends [1, 3, 4, 5, 7] - execute full release smoke and GUI QA

Critical path: Task 2 -> Task 6 -> Task 7 -> Task 8

### Dependency matrix
| Task | Depends on | Blocks | Can parallelize with |
|------|------------|--------|----------------------|
| 1    | none       | 8      | 2, 3, 4, 5           |
| 2    | none       | 6, 8   | 1, 3, 4, 5           |
| 3    | none       | 8      | 1, 2, 4, 5           |
| 4    | none       | 8      | 1, 2, 3, 5           |
| 5    | none       | 6, 8   | 1, 2, 3, 4           |
| 6    | 2, 5       | 7, 8   | none                 |
| 7    | 6          | 8      | none                 |
| 8    | 1, 3, 4, 5, 7 | final | none              |

## Todos
> Implementation + Test = ONE task. Never separate.
> Every task MUST have: References + Acceptance Criteria + QA Scenarios + Commit.

- [ ] 1. Deterministic centered settings-window placement

  What to do: Add the missing `SettingsWindowPlacement` helper expected by the existing test, and change `SettingsWindowCoordinator` to compute a centered frame from the active/main screen's visible frame before showing the settings window. Prefer a small internal `enum` or `struct` in `SettingsWindowCoordinator.swift` unless it pushes the file over 250 pure LOC. Replace `window.center()` with `window.setFrame(SettingsWindowPlacement.centeredFrame(...), display: false)` before `makeKeyAndOrderFront`. Keep `NSApp.activate(ignoringOtherApps: true)` and single-window reuse.
  Must NOT do: Do not add a second settings window scene, Dock window group, private activation API, or a new package dependency.

  Parallelization: Can parallel: YES | Wave 1 | Blocks: [8] | Blocked by: []

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/SettingsWindowCoordinator.swift:20` - current window size, title, center call, hosted `ContentView`, and reuse boundary.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/BridgeApp.swift:43` - current launch-time `MenuBarIcon` task that opens settings once.
  - Test:     `Tests/WorkshopWallpaperBridgeAppTests/SettingsWindowPlacementTests.swift:4` - existing failing TDD test for exact centered geometry.
  - Evidence: `.omo/ulw-loop/evidence/green-remove-test.txt:22` - current compile failure because `SettingsWindowPlacement` is missing.
  - API/Type: `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:7` - model type passed into the hosted settings view.
  - External: `https://developer.apple.com/documentation/appkit/nswindow/center%28%29` - Apple says `center()` positions but does not show the window.
  - External: `https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront%28_%3A%29` - showing/focusing the window is done by `makeKeyAndOrderFront`.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && swift test --filter SettingsWindowPlacementTests 2>&1 | tee evidence/task-1-settings-placement.txt` exits 0.
  - [ ] `grep -R "window.center()" -n Sources/WorkshopWallpaperBridgeApp` returns no matches.
  - [ ] `swift build 2>&1 | tee evidence/task-1-swift-build.txt` exits 0.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: settings opens centered on source-run launch
    Tool:     computer-use
    Steps:    In /Users/lyu/01_Project/01_Projects/wallpaper-engine-local-bridge run `swift run WorkshopWallpaperBridge`; wait for the settings window titled "Workshop Wallpaper Bridge Settings"; capture a full-screen screenshot to evidence/task-1-centered-launch.png; compare the window midpoint to the visible screen midpoint.
    Expected: The settings window is visible without using the Dock, and its midpoint is within 24 px horizontally and vertically of the visible screen midpoint.
    Evidence: evidence/task-1-centered-launch.png

  Scenario: closing and reopening settings keeps a visible centered window
    Tool:     computer-use
    Steps:    With the app still running, close the settings window, open the menu-bar icon, choose "Open Settings", capture evidence/task-1-reopen-settings.png.
    Expected: Exactly one settings window is visible, it is focused, and it remains centered within the same 24 px tolerance.
    Evidence: evidence/task-1-reopen-settings.png
  ```

  Commit: YES | Message: `fix(app): center settings window on launch` | Files: [Sources/WorkshopWallpaperBridgeApp/SettingsWindowCoordinator.swift, Tests/WorkshopWallpaperBridgeAppTests/SettingsWindowPlacementTests.swift]

- [ ] 2. Core library deletion safety

  What to do: Keep or complete `LibraryStore.removeAsset(id:)`, then harden its path guard so it deletes only directories truly inside `root/Assets`, not arbitrary paths with a shared prefix. Add tests for imported-copy deletion, missing-id no-op, and manifest entries pointing outside the app-managed assets root. Preserve the original selected source file/folder.
  Must NOT do: Do not add Trash integration, do not delete original source media, and do not change import storage layout unless required to fix a failing test.

  Parallelization: Can parallel: YES | Wave 1 | Blocks: [6, 8] | Blocked by: []

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Sources/WorkshopWallpaperCore/LibraryStore.swift:100` - current `removeAsset(id:)` manifest/delete flow.
  - Pattern:  `Sources/WorkshopWallpaperCore/LibraryStore.swift:130` - current directory-removal guard; replace prefix-only checking with a component/path-boundary-safe helper.
  - Pattern:  `Sources/WorkshopWallpaperCore/LibraryStore.swift:38` - manual-video import creates app-managed directories that deletion should remove.
  - API/Type: `Sources/WorkshopWallpaperCore/Models.swift:34` - `WallpaperAsset.ID` and `projectDirectory` fields used by manifest deletion.
  - Test:     `Tests/WorkshopWallpaperCoreTests/LibraryStoreTests.swift:89` - existing deletion test for imported manual video.
  - Test:     `Tests/WorkshopWallpaperCoreTests/Fixture.swift:4` - temp-directory helper pattern.
  - Evidence: `.omo/ulw-loop/evidence/red-center-remove-tests.txt:7` - earlier red test before `removeAsset` existed.
  - External: `https://developer.apple.com/documentation/foundation/filemanager/removeitem%28at%3A%29` - `removeItem(at:)` removes directory contents immediately.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && swift test --filter LibraryStoreTests 2>&1 | tee evidence/task-2-library-delete-tests.txt` exits 0.
  - [ ] `grep -n "func removeAsset" Sources/WorkshopWallpaperCore/LibraryStore.swift` finds one public method.
  - [ ] `grep -n "hasPrefix(assetsRoot" Sources/WorkshopWallpaperCore/LibraryStore.swift` returns no matches if the safer helper replaced the prefix-only guard.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: imported copy is deleted while original source remains
    Tool:     bash
    Steps:    `mkdir -p evidence && swift test --filter 'LibraryStoreTests/testRemoveAssetDeletesLibraryDirectoryAndManifestEntry' 2>&1 | tee evidence/task-2-delete-copy.txt`
    Expected: Command exits 0; test asserts empty manifest, removed imported directory, and existing original source file.
    Evidence: evidence/task-2-delete-copy.txt

  Scenario: manifest entry outside library root is not recursively deleted
    Tool:     bash
    Steps:    `mkdir -p evidence && swift test --filter 'LibraryStoreTests/testRemoveAssetDoesNotDeleteOutsideAssetsRoot' 2>&1 | tee evidence/task-2-delete-outside-root.txt`
    Expected: Command exits 0; outside directory/file still exists and manifest entry is removed or ignored according to the implemented test name.
    Evidence: evidence/task-2-delete-outside-root.txt
  ```

  Commit: YES | Message: `fix(core): remove imported library assets safely` | Files: [Sources/WorkshopWallpaperCore/LibraryStore.swift, Tests/WorkshopWallpaperCoreTests/LibraryStoreTests.swift]

- [ ] 3. Manual video import and CLI import-video regression

  What to do: Preserve `LibraryStore.importVideoFile(_:)`, `AppViewModel.importVideoFile(_:)`, and `wwbctl import-video`. If any regression appears while finishing deletion/window work, fix it in the smallest local place. Keep supported extensions as MP4/MOV/M4V playable and WebM/MKV/AVI needing conversion.
  Must NOT do: Do not add network import, Steam download, transcoding during import, or new file-type promises beyond the current README.

  Parallelization: Can parallel: YES | Wave 1 | Blocks: [8] | Blocked by: []

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Sources/WorkshopWallpaperCore/LibraryStore.swift:38` - current manual video import implementation.
  - Pattern:  `Sources/WorkshopWallpaperCore/LibraryStore.swift:215` - current supported manual video extension lists.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:85` - `NSOpenPanel` and app-level import path.
  - Pattern:  `Sources/wwbctl/main.swift:25` - CLI command dispatch for `import-video`.
  - Pattern:  `Sources/wwbctl/main.swift:62` - CLI implementation of `import-video`.
  - Test:     `Tests/WorkshopWallpaperCoreTests/LibraryStoreTests.swift:42` - copy-only-selected-video test.
  - Test:     `Tests/WorkshopWallpaperCoreTests/LibraryStoreTests.swift:64` - unsupported extension test.
  - Test:     `Tests/WorkshopWallpaperCoreTests/LibraryStoreTests.swift:75` - conversion-format status test.
  - External: `https://developer.apple.com/documentation/foundation/filemanager/copyitem%28at%3Ato%3A%29` - file-copy behavior used by import.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && swift test --filter LibraryStoreTests 2>&1 | tee evidence/task-3-video-import-tests.txt` exits 0.
  - [ ] `mkdir -p evidence && tmp="$(mktemp -d)" && printf 'video' > "$tmp/Loop.mp4" && swift run wwbctl import-video "$tmp/Loop.mp4" --library "$tmp/library" 2>&1 | tee evidence/task-3-cli-import-video.txt && test -f "$tmp/library/library.json"` exits 0.
  - [ ] `tmp="$(mktemp -d)" && printf 'text' > "$tmp/notes.txt" && ! swift run wwbctl import-video "$tmp/notes.txt" --library "$tmp/library" > evidence/task-3-cli-unsupported.out 2> evidence/task-3-cli-unsupported.err` exits 0 and `grep -q "not supported for manual video import" evidence/task-3-cli-unsupported.err` exits 0.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: CLI imports an MP4 into a temp library
    Tool:     bash
    Steps:    `mkdir -p evidence && tmp="$(mktemp -d)" && printf 'video' > "$tmp/Loop.mp4" && swift run wwbctl import-video "$tmp/Loop.mp4" --library "$tmp/library" 2>&1 | tee evidence/task-3-cli-import-video.txt && grep -q '"title" : "Loop"' "$tmp/library/library.json"`
    Expected: Command exits 0; output starts with `imported Loop into`; manifest contains title `Loop`.
    Evidence: evidence/task-3-cli-import-video.txt

  Scenario: CLI rejects unsupported file type
    Tool:     bash
    Steps:    `mkdir -p evidence && tmp="$(mktemp -d)" && printf 'text' > "$tmp/notes.txt" && ! swift run wwbctl import-video "$tmp/notes.txt" --library "$tmp/library" > evidence/task-3-cli-unsupported.out 2> evidence/task-3-cli-unsupported.err && grep -q ".txt is not supported for manual video import." evidence/task-3-cli-unsupported.err`
    Expected: Command exits 0 overall because the failing command is negated; stderr contains the exact unsupported-extension message.
    Evidence: evidence/task-3-cli-unsupported.err
  ```

  Commit: YES | Message: `test(cli): cover manual video import` | Files: [Sources/WorkshopWallpaperCore/LibraryStore.swift, Sources/wwbctl/main.swift, Tests/WorkshopWallpaperCoreTests/LibraryStoreTests.swift]

- [ ] 4. Package and documentation contract for menu-bar/local-only release

  What to do: Ensure package metadata, Info.plist generation, and English/Korean docs match the v0.2.1 behavior: menu-bar utility, Add Video File, `wwbctl import-video`, local-only scope, no private APIs, and no original-folder modification. Keep `LSUIElement=true` in the generated app bundle.
  Must NOT do: Do not add notarization, signing, downloader language, or claims that animated Lock Screen control is supported.

  Parallelization: Can parallel: YES | Wave 1 | Blocks: [8] | Blocked by: []

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Scripts/package-app.sh:16` - generated Info.plist body.
  - Pattern:  `Scripts/package-app.sh:33` - current v0.2.1 version fields.
  - Pattern:  `Scripts/package-app.sh:37` - current `LSUIElement` key.
  - Pattern:  `README.md:19` - current Quick Start app launch/menu-bar steps.
  - Pattern:  `README.md:59` - Add Video File support copy.
  - Pattern:  `README.md:117` - CLI command block with `import-video`.
  - Pattern:  `README.ko.md:19` - Korean Quick Start mirror.
  - External: `https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement` - `LSUIElement` Info.plist key.
  - External: `https://developer.apple.com/documentation/swiftui/menubarextra` - SwiftUI menu-bar app scene.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && bash Scripts/package-app.sh 2>&1 | tee evidence/task-4-package.txt` exits 0.
  - [ ] `plutil -extract LSUIElement raw -o - "dist/Workshop Wallpaper Bridge.app/Contents/Info.plist" | tee evidence/task-4-lsuielement.txt` prints `true`.
  - [ ] `grep -q "swift run wwbctl import-video" README.md && grep -q "swift run wwbctl import-video" README.ko.md`.
  - [ ] `grep -q "does not use private APIs" README.md && grep -q "private API" README.ko.md`.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: package script creates menu-bar app bundle
    Tool:     bash
    Steps:    `mkdir -p evidence && bash Scripts/package-app.sh 2>&1 | tee evidence/task-4-package.txt && test -x "dist/Workshop Wallpaper Bridge.app/Contents/MacOS/Workshop Wallpaper Bridge" && plutil -extract LSUIElement raw -o - "dist/Workshop Wallpaper Bridge.app/Contents/Info.plist" | tee evidence/task-4-lsuielement.txt`
    Expected: Command exits 0; zip path is printed; executable exists; `LSUIElement` evidence is `true`.
    Evidence: evidence/task-4-package.txt

  Scenario: docs still reject private/download scope
    Tool:     bash
    Steps:    `mkdir -p evidence && { grep -n "does not download Steam Workshop" README.md; grep -n "does not use private APIs" README.md; grep -n "Steam Workshop 자료를 다운로드하지 않습니다" README.ko.md; } | tee evidence/task-4-doc-guardrails.txt`
    Expected: Command exits 0; English and Korean guardrail lines are present.
    Evidence: evidence/task-4-doc-guardrails.txt
  ```

  Commit: YES | Message: `docs(release): document v0.2.1 menu-bar import flow` | Files: [Scripts/package-app.sh, README.md, README.ko.md]

- [ ] 5. Dirty-tree hygiene and Swift file-size constraints

  What to do: Keep current user/runtime artifacts intact, but do not stage `.omo/`. After Tasks 1-4 edits, check touched Swift files for pure LOC under 250. If `AppViewModel.swift` or `LibraryStore.swift` would cross 250 pure LOC in later tasks, split only along existing boundaries (`SettingsWindowCoordinator`, `StatusMenu`, or a tiny core helper) instead of stuffing more behavior into a large file.
  Must NOT do: Do not delete `.omo/`, do not rewrite unrelated README/package changes, and do not split files preemptively if the limit is still satisfied.

  Parallelization: Can parallel: YES | Wave 1 | Blocks: [6, 8] | Blocked by: []

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:7` - already 198 total lines before delete flow; watch size.
  - Pattern:  `Sources/WorkshopWallpaperCore/LibraryStore.swift:3` - already 238 total lines before hardening; split if added tests require source growth above pure LOC limit.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/StatusMenu.swift:4` - small existing menu boundary.
  - Pattern:  `.omo/ulw-loop/status.latest.json:1` - runtime state exists and should not be treated as product source.
  - Test:     `Tests/WorkshopWallpaperBridgeAppTests/SettingsWindowPlacementTests.swift:1` - bridge test target is currently untracked and must be deliberately included only if still used.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && git status --short | tee evidence/task-5-git-status-before-final.txt` records remaining dirty files.
  - [ ] `awk 'NF && $1 !~ /^\\/\\// { count[FILENAME]++ } END { for (f in count) if (f ~ /^Sources\\/.*\\.swift$/ && count[f] > 250) { print f, count[f]; bad=1 } exit bad }' Sources/WorkshopWallpaperBridgeApp/*.swift Sources/WorkshopWallpaperCore/*.swift Sources/wwbctl/main.swift | tee evidence/task-5-pure-loc.txt` exits 0.
  - [ ] `git status --short .omo | tee evidence/task-5-omo-status.txt` may show `.omo/`, but no implementation commit may include `.omo/`.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: source files stay under the size limit
    Tool:     bash
    Steps:    `mkdir -p evidence && awk 'NF && $1 !~ /^\\/\\// { count[FILENAME]++ } END { for (f in count) if (f ~ /^Sources\\/.*\\.swift$/ && count[f] > 250) { print f, count[f]; bad=1 } exit bad }' Sources/WorkshopWallpaperBridgeApp/*.swift Sources/WorkshopWallpaperCore/*.swift Sources/wwbctl/main.swift | tee evidence/task-5-pure-loc.txt`
    Expected: Command exits 0 and prints no oversized source file.
    Evidence: evidence/task-5-pure-loc.txt

  Scenario: runtime artifacts are not staged for product commits
    Tool:     bash
    Steps:    `mkdir -p evidence && git diff --cached --name-only | tee evidence/task-5-staged-files.txt && ! grep -q '^\\.omo/' evidence/task-5-staged-files.txt`
    Expected: Command exits 0; no staged `.omo/` path appears.
    Evidence: evidence/task-5-staged-files.txt
  ```

  Commit: NO | Message: `chore(repo): verify release hygiene` | Files: []

- [ ] 6. AppViewModel deletion action and playback state

  What to do: Add a `removeSelectedLibraryAsset()` app action that handles no selection with a clear status, deletes the selected app-managed library item through `LibraryStore.removeAsset(id:)`, reloads the library, clears or moves selection deterministically, and stops playback only when the deleted item is the currently playing asset. Add minimal state such as `playingAssetId` if needed. Add a test-only/internal initializer for injecting a temporary `LibraryStore` into `AppViewModel` so XCTest can cover this without touching the real Application Support folder.
  Must NOT do: Do not make the UI delete original files, do not always stop unrelated playback if a different asset is active, and do not add a global singleton store.

  Parallelization: Can parallel: NO | Wave 2 | Blocks: [7, 8] | Blocked by: [2, 5]

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:36` - selected scanned/library asset computed properties.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:70` - existing `importSelected()` status/selection pattern.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:97` - existing manual-video import status/selection pattern.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:110` - `playSelected()` success path; set `playingAssetId` only after successful playback.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:164` - `stopPlayback()` should clear playback state.
  - API/Type: `Sources/WorkshopWallpaperCore/LibraryStore.swift:100` - deletion API to call.
  - Test:     `Tests/WorkshopWallpaperCoreTests/LibraryStoreTests.swift:89` - lower-level delete behavior already covered.
  - Test:     `Tests/WorkshopWallpaperBridgeAppTests/SettingsWindowPlacementTests.swift:1` - app test target pattern with `@testable import WorkshopWallpaperBridgeApp`.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && swift test --filter AppViewModelLibraryDeletionTests 2>&1 | tee evidence/task-6-viewmodel-delete-tests.txt` exits 0.
  - [ ] `swift test --filter LibraryStoreTests 2>&1 | tee evidence/task-6-core-delete-regression.txt` exits 0.
  - [ ] `swift build 2>&1 | tee evidence/task-6-swift-build.txt` exits 0.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: ViewModel removes selected imported item
    Tool:     bash
    Steps:    `mkdir -p evidence && swift test --filter 'AppViewModelLibraryDeletionTests/testRemoveSelectedLibraryAssetDeletesImportedCopyAndClearsSelection' 2>&1 | tee evidence/task-6-viewmodel-delete-selected.txt`
    Expected: Command exits 0; test proves copied directory removal, manifest reload, and cleared or deterministic selection.
    Evidence: evidence/task-6-viewmodel-delete-selected.txt

  Scenario: ViewModel handles delete with no selection
    Tool:     bash
    Steps:    `mkdir -p evidence && swift test --filter 'AppViewModelLibraryDeletionTests/testRemoveSelectedLibraryAssetWithoutSelectionShowsStatus' 2>&1 | tee evidence/task-6-viewmodel-delete-empty.txt`
    Expected: Command exits 0; status is the exact no-selection message, and the library manifest is unchanged.
    Evidence: evidence/task-6-viewmodel-delete-empty.txt
  ```

  Commit: YES | Message: `feat(app): remove selected library asset` | Files: [Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift, Tests/WorkshopWallpaperBridgeAppTests/AppViewModelLibraryDeletionTests.swift]

- [ ] 7. Section-2 delete UI wiring

  What to do: Add a section-2 delete/remove control near `Play on Desktop`, `Convert Video`, and `Set Still Wallpaper`. Use a label such as `Remove from Library` or `Delete from Library`, disable it when no library item is selected or while conversion is working, and call `model.removeSelectedLibraryAsset()`. Add an accessibility identifier/label if practical so GUI automation can find it. If adding a confirmation dialog, keep it simple and make QA steps cover the confirm action.
  Must NOT do: Do not move Add Video File out of section 2, do not add nested cards or visual redesign, and do not hide existing play/convert/still-wallpaper actions.

  Parallelization: Can parallel: NO | Wave 2 | Blocks: [8] | Blocked by: [6]

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/ContentView.swift:74` - section 2 library panel.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/ContentView.swift:92` - current action button row for library selection.
  - Pattern:  `Sources/WorkshopWallpaperBridgeApp/ContentView.swift:129` - shared asset list and `List(selection:)` pattern.
  - API/Type: `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:40` - selected library asset used for button disabled state.
  - API/Type: `Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift:14` - `isWorking` should disable destructive action during conversion.
  - External: `https://developer.apple.com/documentation/swiftui/button` - standard SwiftUI button behavior.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && swift build 2>&1 | tee evidence/task-7-ui-build.txt` exits 0.
  - [ ] `swift test --filter AppViewModelLibraryDeletionTests 2>&1 | tee evidence/task-7-viewmodel-regression.txt` exits 0.
  - [ ] `rg -n "Remove from Library|Delete from Library|removeSelectedLibraryAsset" Sources/WorkshopWallpaperBridgeApp/ContentView.swift | tee evidence/task-7-delete-ui-rg.txt` finds the new control and action call.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: delete button is visible and disabled without selection
    Tool:     computer-use
    Steps:    Run `swift run WorkshopWallpaperBridge`; wait for settings; inspect section 2 button row; capture evidence/task-7-delete-disabled.png.
    Expected: The delete/remove control is visible in section 2 and disabled when no imported project is selected.
    Evidence: evidence/task-7-delete-disabled.png

  Scenario: delete selected imported item from section 2
    Tool:     computer-use
    Steps:    Seed an imported item with `tmp="$(mktemp -d)" && printf 'video' > "$tmp/Loop.mp4" && swift run wwbctl import-video "$tmp/Loop.mp4"`; launch `swift run WorkshopWallpaperBridge`; select `Loop` in section 2; click `Remove from Library` or `Delete from Library`; confirm if prompted; capture evidence/task-7-delete-selected.png.
    Expected: `Loop` disappears from section 2, status reports it was removed, and no error dialog appears.
    Evidence: evidence/task-7-delete-selected.png
  ```

  Commit: YES | Message: `feat(ui): expose library item deletion` | Files: [Sources/WorkshopWallpaperBridgeApp/ContentView.swift, Sources/WorkshopWallpaperBridgeApp/AppViewModel.swift]

- [ ] 8. Full release smoke, packaged GUI QA, and evidence collation

  What to do: Run the complete verification surface after Tasks 1-7: focused tests, full test suite, build, package, CLI import-video happy/error paths, and packaged app GUI launch/import/delete. Capture evidence in `evidence/`. Fix only regressions introduced by this finish scope; leave unrelated pre-existing dirtiness alone and report it.
  Must NOT do: Do not declare complete on green unit tests alone; this app must be used through the packaged macOS GUI surface.

  Parallelization: Can parallel: NO | Wave 2 | Blocks: [final] | Blocked by: [1, 3, 4, 5, 7]

  References (executor has NO interview context - be exhaustive):
  - Pattern:  `Package.swift:23` - core test target.
  - Pattern:  `Package.swift:27` - bridge app test target.
  - Pattern:  `Scripts/package-app.sh:11` - release build command used by package script.
  - Pattern:  `Scripts/package-app.sh:47` - zip artifact path.
  - Pattern:  `README.md:100` - documented local bundle build command.
  - Pattern:  `README.md:113` - documented CLI commands.
  - External: `https://developer.apple.com/documentation/swiftui/menubarextra` - packaged menu-bar utility behavior.
  - External: `https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement` - no Dock/app-switcher behavior.

  Acceptance criteria (agent-executable only):
  - [ ] `mkdir -p evidence && swift test 2>&1 | tee evidence/task-8-swift-test.txt` exits 0.
  - [ ] `swift build 2>&1 | tee evidence/task-8-swift-build.txt` exits 0.
  - [ ] `bash Scripts/package-app.sh 2>&1 | tee evidence/task-8-package.txt` exits 0 and `test -f dist/WorkshopWallpaperBridge-macOS-arm64.zip` exits 0.
  - [ ] `plutil -extract LSUIElement raw -o - "dist/Workshop Wallpaper Bridge.app/Contents/Info.plist" | tee evidence/task-8-lsuielement.txt` prints `true`.
  - [ ] `tmp="$(mktemp -d)" && printf 'video' > "$tmp/Loop.mp4" && swift run wwbctl import-video "$tmp/Loop.mp4" --library "$tmp/library" 2>&1 | tee evidence/task-8-cli-import-video.txt && grep -q '"title" : "Loop"' "$tmp/library/library.json"` exits 0.
  - [ ] `git status --short | tee evidence/task-8-final-git-status.txt` records only intentional product/doc/plan/evidence changes plus any known ignored runtime artifacts.

  QA scenarios (MANDATORY - task incomplete without these):
  > Name the exact tool AND its exact invocation - not "verify it works". Browser use: use Chrome to drive the page; if Chrome is not available, download and use agent-browser (https://github.com/vercel-labs/agent-browser). Computer use: OS-level GUI automation for a non-browser desktop app.
  ```
  Scenario: packaged app launches as menu-bar utility with centered settings
    Tool:     computer-use
    Steps:    Run `bash Scripts/package-app.sh`; run `open "dist/Workshop Wallpaper Bridge.app"`; wait for "Workshop Wallpaper Bridge Settings"; capture full-screen screenshot evidence/task-8-packaged-centered-launch.png; inspect Dock/app switcher visually if available.
    Expected: Settings window appears automatically, is centered within 24 px of the visible screen midpoint, app menu-bar icon exists, and no Dock/app-switcher entry is visible for the packaged app.
    Evidence: evidence/task-8-packaged-centered-launch.png

  Scenario: packaged app imports and deletes a local MP4 with no error dialog
    Tool:     computer-use
    Steps:    Create `evidence/manual-qa-video.mp4` with `printf 'video' > evidence/manual-qa-video.mp4`; in the packaged app settings window click `Add Video File`; choose `evidence/manual-qa-video.mp4`; verify it appears in section 2; select it; click `Remove from Library` or `Delete from Library`; confirm if prompted; capture evidence/task-8-import-delete-gui.png.
    Expected: The video appears after import, disappears after deletion, status text reports success, the original `evidence/manual-qa-video.mp4` still exists, and no error dialog appears.
    Evidence: evidence/task-8-import-delete-gui.png
  ```

  Commit: YES | Message: `chore(release): verify v0.2.1 app flow` | Files: [evidence/task-8-swift-test.txt, evidence/task-8-swift-build.txt, evidence/task-8-package.txt, evidence/task-8-lsuielement.txt, evidence/task-8-cli-import-video.txt]

## Final verification wave (MANDATORY - after all implementation tasks)
> Runs in PARALLEL. ALL must APPROVE. Surface results to the caller and wait for an explicit "okay" before declaring complete.
- [ ] F1. Plan compliance audit - every task done, every acceptance criterion met
- [ ] F2. Code quality review - diagnostics clean, idioms match, no dead code
- [ ] F3. Real manual QA - every QA scenario executed with evidence captured
- [ ] F4. Scope fidelity - nothing extra shipped beyond Must-Have, nothing Must-NOT-Have introduced

## Commit strategy
- One logical change per commit. Conventional Commits (`<type>(<scope>): <subject>` body + footer).
- Include the repo's Lore trailers in each commit body when committing under this AGENTS scope: `Constraint:`, `Rejected:`, `Confidence:`, `Scope-risk:`, `Directive:`, `Tested:`, and `Not-tested:` when they add decision context.
- Atomic: every commit builds and passes tests on its own.
- No "WIP" / "fix typo squash later" commits on the final branch - clean up before merge.
- Reference the plan file path in the final commit footer: `Plan: plans/finish-v021-settings-delete.md`.
- Do not stage `.omo/` runtime files unless the user explicitly asks to preserve OMX state artifacts in git.

## Success criteria
- All Must-Have shipped; all QA scenarios pass with captured evidence; F1-F4 approved; commit history clean.
