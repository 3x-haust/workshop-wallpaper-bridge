import SwiftUI
import WorkshopWallpaperCore

struct ContentView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                scanPanel
                Divider()
                libraryPanel
            }
            Divider()
            statusBar
        }
        .alert(item: $model.updateAlert) { alert in
            updateAlert(alert)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workshop Wallpaper Bridge")
                        .font(.title2.weight(.semibold))
                    Text("Menu bar wallpaper utility for copied Wallpaper Engine projects.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") {
                    model.stopPlayback()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }

            HStack(spacing: 14) {
                headerToggle("Open at Login", isOn: $model.launchAtLogin)
                headerToggle("Auto-pause behind apps", isOn: $model.autoPauseWhenCovered)
                headerToggle("Animate Screen Saver", isOn: $model.lockScreenAnimationEnabled)
                    .disabled(!model.isProUnlocked)
                headerToggle("Auto-check Updates", isOn: $model.automaticallyCheckForUpdates)
                    .disabled(!model.isProUnlocked)
            }
            proPanel

            HStack(spacing: 8) {
                Button("Check Updates") {
                    model.checkForUpdates()
                }
                .disabled(model.isCheckingForUpdates)
                if model.availableUpdate != nil {
                    Button("Download Update") {
                        model.openAvailableUpdate()
                    }
                }
                Spacer()
            }
        }
        .padding()
    }

    private var proPanel: some View {
        HStack(spacing: 8) {
            Text(model.isProUnlocked ? "Pro" : "Free")
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.isProUnlocked ? .green : .secondary)
                .frame(width: 38, alignment: .leading)
            Text(model.proStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if model.isProUnlocked {
                Button("Remove Pro") {
                    model.clearProLicense()
                }
            } else {
                TextField("WWB-PRO-XXXX-XXXX-CHECK", text: $model.proLicenseKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                Button("Unlock Pro") {
                    model.activateProLicense()
                }
                .disabled(model.proLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func headerToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .toggleStyle(.switch)
        .font(.callout)
        .frame(width: 220, alignment: .leading)
    }

    private var scanPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Choose the copied Workshop folder")
                .font(.headline)
            Text(
                "Select the `431960` folder you copied from Windows Steam, "
                    + "or add your own video from the library side."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(".../steamapps/workshop/content/431960", text: $model.sourcePath)
                Button("Browse") {
                    model.chooseFolder()
                }
                Button("Scan") {
                    model.scanSource()
                }
            }
            assetList(
                title: "Scanned Projects",
                assets: model.scannedAssets,
                selection: Binding(
                    get: { model.selectedScannedAssetIds },
                    set: { model.selectScannedAssets($0) }
                )
            )
            HStack {
                Button(importButtonTitle) {
                    model.importSelected()
                }
                .disabled(model.selectedScannedAssetIds.isEmpty)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 460)
    }

    private var libraryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Play from your Mac library")
                .font(.headline)
            HStack {
                Text("Imported files stay local. The original files are not modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Display", selection: $model.displayMode) {
                    ForEach(WallpaperDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Button("Add Video File") {
                    model.chooseVideoFile()
                }
            }
            libraryAssetList(
                title: "Imported Projects",
                assets: model.libraryAssets,
                selection: Binding(
                    get: { model.selectedLibraryAssetIds },
                    set: { model.selectLibraryAssets($0) }
                )
            )
            libraryActions
            Text(
                "Video wallpapers use a generated video frame for still wallpaper. "
                    + "Still images are written to the macOS Lock Screen cache when available. "
                    + "Screen Saver animation uses the bundled macOS screen saver and supports MP4, MOV, and M4V."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 460)
    }

    private var importButtonTitle: String {
        model.selectedScannedAssetCount > 1
            ? "Import Selected (\(model.selectedScannedAssetCount))"
            : "Import Selected"
    }

    private var libraryActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                actionButton("Play on Desktop") {
                    model.playSelected()
                }
                .disabled(model.selectedLibraryAsset == nil)
                actionButton("Convert Video") {
                    model.convertSelected()
                }
                .disabled(model.selectedLibraryAsset?.supportStatus != .needsConversion || model.isWorking)
                actionButton("Set Still Wallpaper") {
                    model.setStillWallpaper()
                }
                .disabled(model.selectedLibraryAsset == nil || !model.isProUnlocked)
                Spacer()
            }
            HStack(spacing: 8) {
                actionButton("Screen Saver Settings") {
                    model.openScreenSaverSettings()
                }
                .disabled(!model.isProUnlocked)
                actionButton(model.selectedLibraryAssetCount > 1 ? "Remove Selected" : "Remove") {
                    model.removeSelectedLibraryAssets()
                }
                .disabled(model.selectedLibraryAssetIds.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
                Spacer()
            }
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func updateAlert(_ alert: UpdateAlert) -> Alert {
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text("OK"))
        )
    }

    private var statusBar: some View {
        HStack {
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.status)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func assetList(
        title: String,
        assets: [WallpaperAsset],
        selection: Binding<Set<WallpaperAsset.ID>>
    ) -> some View {
        List(selection: selection) {
            ForEach(assets) { asset in
                AssetRow(asset: asset)
                    .tag(asset.id)
            }
        }
        .overlay {
            if assets.isEmpty {
                Text(title)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func libraryAssetList(
        title: String,
        assets: [WallpaperAsset],
        selection: Binding<Set<WallpaperAsset.ID>>
    ) -> some View {
        List(selection: selection) {
            ForEach(assets) { asset in
                AssetRow(asset: asset)
                    .tag(asset.id)
                    .contextMenu {
                        Button("Remove") {
                            model.selectLibraryAssets([asset.id])
                            model.removeSelectedLibraryAssets()
                        }
                    }
            }
        }
        .overlay {
            if assets.isEmpty {
                Text(title)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AssetRow: View {
    let asset: WallpaperAsset

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            Text(asset.projectDirectory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let issue = asset.issues.first {
                Text(issue.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
            Spacer()
            Text(asset.kind.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(asset.supportStatus.rawValue)
                .font(.caption)
                .foregroundStyle(asset.supportStatus == .playable ? .green : .orange)
        }
        .padding(.vertical, 4)
    }
}
