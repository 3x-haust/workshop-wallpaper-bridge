import SwiftUI
import WorkshopWallpaperCore

/// The main "Library" tab: importing a copied Workshop folder, browsing the
/// Mac-local library, and playing/managing wallpapers. The imported-library
/// list is given the most vertical space; scanned-but-not-yet-imported
/// projects only take a small strip above it, and only while there are any.
struct LibraryTabView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            importRow
            if !model.scannedAssets.isEmpty {
                scannedSection
            }
            toolbarRow
            libraryList
            AssetPreview(
                asset: model.selectedLibraryAsset,
                placeholderTitle: model.L("library.preview.placeholder"),
                placeholderDescription: model.L("library.preview.empty")
            )
            rotationRow
            actionRow
        }
        .padding()
        .confirmationDialog(
            removeConfirmationTitle,
            isPresented: Binding(
                get: { model.pendingLibraryRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelPendingLibraryRemoval()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: model.pendingLibraryRemoval
        ) { _ in
            Button(model.L("library.remove.confirm.button"), role: .destructive) {
                model.removeSelectedLibraryAssets()
            }
            Button(model.L("common.cancel"), role: .cancel) {
                model.cancelPendingLibraryRemoval()
            }
        } message: { _ in
            Text(model.L("library.remove.confirm.message"))
        }
    }

    private var removeConfirmationTitle: String {
        guard let pending = model.pendingLibraryRemoval else {
            return model.L("library.remove.confirm.title.fallback")
        }
        return String(format: model.L("library.remove.confirm.title"), pending.title)
    }

    private var importRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.L("library.source.title"))
                    .font(.subheadline.weight(.semibold))
                HelpPopoverButton(
                    title: model.L("library.import.help.title"),
                    message: model.L("library.import.help.body")
                )
                Spacer()
            }
            HStack(spacing: 8) {
                TextField(model.L("library.source.placeholder"), text: $model.sourcePath)
                Button(model.L("library.browse")) {
                    model.chooseFolder()
                }
                Button(model.L("library.scan")) {
                    model.scanSource()
                }
            }
        }
    }

    private var scannedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(model.L("library.scanned.empty")) (\(model.scannedAssets.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(model.L("library.sort.title"), selection: $model.scannedSortOrder) {
                    ForEach(ScannedAssetSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                Button(importButtonTitle) {
                    model.importSelected()
                }
                .disabled(model.selectedScannedAssetIds.isEmpty)
            }
            List(
                selection: Binding(
                    get: { model.selectedScannedAssetIds },
                    set: { model.selectScannedAssets($0) }
                )
            ) {
                ForEach(model.scannedAssets) { asset in
                    AssetRow(
                        asset: asset,
                        sceneVideoRenderRevision: model.sceneVideoRenderRevision,
                        isNew: model.isNewScannedAsset(asset),
                        newBadgeText: model.L("library.new.badge")
                    )
                    .tag(asset.id)
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            AssetPreview(
                asset: model.selectedScannedAsset,
                placeholderTitle: model.L("library.preview.placeholder"),
                placeholderDescription: model.L("library.preview.empty")
            )
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            Text(model.L("library.imported.empty"))
                .font(.headline)
            Spacer()
            Picker(model.L("library.display"), selection: $model.displayMode) {
                ForEach(WallpaperDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Button(model.L("library.addVideo")) {
                model.chooseVideoFile()
            }
        }
    }

    private var libraryList: some View {
        List(
            selection: Binding(
                get: { model.selectedLibraryAssetIds },
                set: { model.selectLibraryAssets($0) }
            )
        ) {
            ForEach(model.libraryAssets) { asset in
                AssetRow(asset: asset, sceneVideoRenderRevision: model.sceneVideoRenderRevision)
                    .tag(asset.id)
                    .contextMenu {
                        contextMenuItems(for: asset)
                    }
            }
        }
        .overlay {
            if model.libraryAssets.isEmpty {
                Text(model.L("library.imported.empty"))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxHeight: .infinity)
    }

    private var rotationRow: some View {
        HStack(spacing: 12) {
            Toggle(model.L("library.rotate"), isOn: $model.rotationEnabled)
                .toggleStyle(.switch)
                .lineLimit(1)
                .fixedSize()
            Toggle(model.L("library.rotate.shuffle"), isOn: $model.rotationShuffle)
                .toggleStyle(.switch)
                .lineLimit(1)
                .fixedSize()
            Picker(model.L("library.rotate.every"), selection: $model.rotationInterval) {
                ForEach(AppViewModel.rotationIntervalOptions, id: \.seconds) { option in
                    Text(option.label).tag(option.seconds)
                }
            }
            .fixedSize()
            Button(model.L("library.rotate.next")) {
                model.nextWallpaper()
            }
            .disabled(!model.rotationEnabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func contextMenuItems(for asset: WallpaperAsset) -> some View {
        Button(model.L("library.convert")) {
            model.selectLibraryAssets([asset.id])
            model.convertSelected()
        }
        .disabled(asset.supportStatus != .needsConversion || model.isWorking)
        Button(model.L("library.setStillWallpaper")) {
            model.selectLibraryAssets([asset.id])
            model.setStillWallpaper()
        }
        Divider()
        Button(model.L("library.remove")) {
            model.selectLibraryAssets([asset.id])
            model.requestRemoveSelectedLibraryAssets()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(model.L("library.play")) {
                model.playSelected()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedLibraryAsset == nil)
            Button(removeButtonTitle) {
                model.requestRemoveSelectedLibraryAssets()
            }
            .disabled(model.selectedLibraryAssetIds.isEmpty)
            .keyboardShortcut(.delete, modifiers: [])
            Menu(model.L("library.more")) {
                Button(model.L("library.convert")) {
                    model.convertSelected()
                }
                .disabled(model.selectedLibraryAsset?.supportStatus != .needsConversion || model.isWorking)
                Button(model.L("library.setStillWallpaper")) {
                    model.setStillWallpaper()
                }
                .disabled(model.selectedLibraryAsset == nil)
                Button(model.L("library.screenSaverSettings")) {
                    model.openScreenSaverSettings()
                }
            }
            .fixedSize()
            Spacer()
            HelpPopoverButton(
                title: model.L("library.help.title"),
                message: model.L("library.help.body")
            )
        }
    }

    private var importButtonTitle: String {
        model.selectedScannedAssetCount > 1
            ? "\(model.L("library.import")) (\(model.selectedScannedAssetCount))"
            : model.L("library.import")
    }

    private var removeButtonTitle: String {
        model.selectedLibraryAssetCount > 1
            ? model.L("library.remove.selected")
            : model.L("library.remove")
    }
}
