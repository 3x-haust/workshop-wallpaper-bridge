import SwiftUI
import WorkshopWallpaperCore

struct LibraryBrowserDetailView: View {
    @ObservedObject var model: AppViewModel
    @State private var showsPreview = false

    var body: some View {
        ScrollView {
            if let asset = model.selectedLibraryAsset {
                VStack(alignment: .leading, spacing: 20) {
                    preview(asset)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(asset.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(model.L("library.kind.\(asset.kind.rawValue)"))
                            .font(.callout).foregroundStyle(BrowserPalette.secondary)
                        LibrarySupportBadge(model: model, asset: asset, sceneVideoRenderRevision: model.sceneVideoRenderRevision)
                        ForEach(Array(asset.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message)
                                .font(.caption).foregroundStyle(BrowserPalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(BrowserPalette.border)
                    VStack(alignment: .leading, spacing: 10) {
                        BrowserSectionLabel(title: model.L("library.display"))
                        WallpaperDisplayModePicker(model: model)
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        HStack(spacing: 8) {
                            Button(model.L("library.play")) { model.playSelected() }
                                .buttonStyle(.borderedProminent)
                                .disabled(asset.supportStatus != .playable)
                            Button(model.L("displays.stop")) { model.stopSelectedPlayback() }
                        }
                        if asset.kind == .web || asset.kind == .scene {
                            Button(model.L("library.playInteractive")) { model.playSelectedInteractively() }
                                .disabled(asset.supportStatus != .playable)
                                .help(model.L("settings.interaction.help"))
                        }
                    }
                    Divider().overlay(BrowserPalette.border)
                    VStack(alignment: .leading, spacing: 12) {
                        BrowserSectionLabel(title: model.L("library.more"))
                        Button(model.L("library.convert")) { model.convertSelected() }
                            .disabled(asset.supportStatus != .needsConversion || model.isWorking)
                        Button(model.L("library.setStillWallpaper")) { model.setStillWallpaper() }
                        Button(model.L("library.screenSaverSettings")) { model.openScreenSaverSettings() }
                        Button(model.L(model.selectedLibraryAssetCount > 1 ? "library.remove.selected" : "library.remove"), role: .destructive) {
                            model.requestRemoveSelectedLibraryAssets()
                        }
                        .disabled(model.isWorking)
                    }
                }
                .padding(20)
            } else {
                BrowserEmptyState(
                    symbol: "sidebar.right",
                    title: model.L("library.preview.placeholder"),
                    message: model.L("library.preview.empty")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserPalette.sidebar)
        .sheet(isPresented: $showsPreview) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.selectedLibraryAsset?.title ?? model.L("library.preview.placeholder"))
                        .font(.headline).lineLimit(2)
                    Spacer()
                    Button(model.L("common.close")) { showsPreview = false }
                        .keyboardShortcut(.cancelAction)
                }
                BrowserThumbnail(url: model.selectedLibraryAsset.flatMap { libraryThumbnailURL(for: $0) }, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .padding(20)
            .frame(width: 560, height: 420)
            .background(BrowserPalette.background)
            .foregroundStyle(BrowserPalette.text)
        }
    }

    private func preview(_ asset: WallpaperAsset) -> some View {
        Button { showsPreview = true } label: {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { BrowserThumbnail(url: libraryThumbnailURL(for: asset), contentMode: .fit) }
                .background(BrowserPalette.background)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .padding(8)
                        .background(BrowserPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.L("library.preview.enlarge"))
        .disabled(libraryThumbnailURL(for: asset) == nil)
    }
}

func libraryThumbnailURL(for asset: WallpaperAsset) -> URL? {
    if let thumbnail = asset.thumbnail { return URL(filePath: thumbnail) }
    if asset.kind == .image, let entrypoint = asset.entrypoint { return URL(filePath: entrypoint) }
    return nil
}

struct LibrarySupportBadge: View {
    @ObservedObject var model: AppViewModel
    let asset: WallpaperAsset
    let sceneVideoRenderRevision: Int

    var body: some View {
        let status = LibraryRowStatusResolver.status(for: asset)
        Label(model.L(statusKey(status)), systemImage: status.isPositive ? "checkmark.circle" : "info.circle")
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.isPositive ? BrowserPalette.accent : BrowserPalette.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(BrowserPalette.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusKey(_ status: LibraryRowDisplayStatus) -> String {
        switch status {
        case .playable: "library.support.playable"
        case .needsFirstRender: "library.support.needsFirstRender"
        case .notPlayable(let support): "library.support.\(support.rawValue)"
        }
    }
}
