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
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workshop Wallpaper Bridge")
                    .font(.title2.weight(.semibold))
                Text("Menu bar wallpaper utility for copied Wallpaper Engine projects.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto-pause behind apps", isOn: $model.autoPauseWhenCovered)
                .toggleStyle(.switch)
            Button("Stop") {
                model.stopPlayback()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        .padding()
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
                selection: $model.selectedScannedAssetId
            )
            HStack {
                Button("Import Selected") {
                    model.importSelected()
                }
                .disabled(model.selectedScannedAsset == nil)
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
            HStack {
                Button("Play on Desktop") {
                    model.playSelected()
                }
                .disabled(model.selectedLibraryAsset == nil)
                Button("Convert Video") {
                    model.convertSelected()
                }
                .disabled(model.selectedLibraryAsset?.supportStatus != .needsConversion || model.isWorking)
                Button("Set Still Wallpaper") {
                    model.setStillWallpaper()
                }
                .disabled(model.selectedLibraryAsset == nil)
                Button(model.selectedLibraryAssetCount > 1 ? "Remove Selected" : "Remove") {
                    model.removeSelectedLibraryAssets()
                }
                .disabled(model.selectedLibraryAssetIds.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
                Spacer()
            }
            Text(
                "Animated Lock Screen is not exposed through a stable public macOS API. "
                    + "Still images can be set through macOS wallpaper settings."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 460)
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
        selection: Binding<WallpaperAsset.ID?>
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
