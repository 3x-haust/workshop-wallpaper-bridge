import AppKit
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
                headerToggle("Auto-check Updates", isOn: $model.automaticallyCheckForUpdates)
            }

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
                previewAsset: model.selectedScannedAsset,
                selection: Binding(
                    get: { model.selectedScannedAssetIds },
                    set: { model.selectScannedAssets($0) }
                )
            )
            HStack {
                Button(importButtonTitle) {
                    model.importSelected()
                }
                .disabled(model.selectedScannedAssetIds.isEmpty || model.isWorking)
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
                previewAsset: model.selectedLibraryAsset,
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
                .disabled(model.selectedLibraryAsset == nil)
                Spacer()
            }
            HStack(spacing: 8) {
                actionButton("Screen Saver Settings") {
                    model.openScreenSaverSettings()
                }
                actionButton(model.selectedLibraryAssetCount > 1 ? "Remove Selected" : "Remove") {
                    model.removeSelectedLibraryAssets()
                }
                .disabled(model.selectedLibraryAssetIds.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle("Rotate Library", isOn: $model.rotationEnabled)
                    .toggleStyle(.switch)
                    .lineLimit(1)
                    .fixedSize()
                Toggle("Shuffle", isOn: $model.rotationShuffle)
                    .toggleStyle(.switch)
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
            }
            HStack(spacing: 12) {
                Picker("Every", selection: $model.rotationInterval) {
                    ForEach(AppViewModel.rotationIntervalOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .fixedSize()
                actionButton("Next") {
                    model.nextWallpaper()
                }
                .disabled(!model.rotationEnabled)
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
            if let progress = model.importProgress {
                ProgressView(value: progress.fraction)
                    .controlSize(.small)
                    .frame(width: 120)
            } else if model.isWorking {
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
        previewAsset: WallpaperAsset?,
        selection: Binding<Set<WallpaperAsset.ID>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            AssetPreview(asset: previewAsset)
        }
    }

    private func libraryAssetList(
        title: String,
        assets: [WallpaperAsset],
        previewAsset: WallpaperAsset?,
        selection: Binding<Set<WallpaperAsset.ID>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            AssetPreview(asset: previewAsset)
        }
    }
}

private struct AssetPreview: View {
    let asset: WallpaperAsset?

    var body: some View {
        HStack(spacing: 12) {
            previewImage
            VStack(alignment: .leading, spacing: 4) {
                Text(asset?.title ?? "Select a wallpaper")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(assetDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let issue = asset?.issues.first {
                    Text(issue.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(minHeight: 112, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var previewImage: some View {
        AssetThumbnail(asset: asset, width: 144, height: 88, cornerRadius: 6)
    }

    private var assetDescription: String {
        guard let asset else {
            return "The selected wallpaper preview appears here."
        }
        return "\(asset.kind.rawValue) · \(asset.supportStatus.rawValue)"
    }
}

private struct AssetRow: View {
    let asset: WallpaperAsset

    var body: some View {
        HStack(spacing: 10) {
            AssetThumbnail(asset: asset, width: 64, height: 40, cornerRadius: 5)
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

private struct AssetThumbnail: View {
    let asset: WallpaperAsset?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.72))
            if let image = previewNSImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width, height: height)
            } else {
                Text(asset?.kind.rawValue.uppercased() ?? "PREVIEW")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel(accessibilityLabel)
    }

    private var previewNSImage: NSImage? {
        guard let url = previewURL else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var previewURL: URL? {
        guard let asset else {
            return nil
        }
        if let thumbnail = asset.thumbnail {
            return URL(filePath: thumbnail)
        }
        guard asset.kind == .image, let entrypoint = asset.entrypoint else {
            return nil
        }
        return URL(filePath: entrypoint)
    }

    private var accessibilityLabel: String {
        guard let asset else {
            return "Wallpaper preview placeholder"
        }
        return "Wallpaper preview for \(asset.title)"
    }
}
