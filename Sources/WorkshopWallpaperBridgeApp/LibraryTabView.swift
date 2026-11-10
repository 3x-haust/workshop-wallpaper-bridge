import AppKit
import SwiftUI
import WorkshopWallpaperCore

struct LibraryTabView: View {
    @ObservedObject var model: AppViewModel
    @State private var showsImport = false
    @State private var showsDetails = false
    @State private var selectionAnchor: String?
    @State private var sortOrder: ScannedAssetSortOrder = .dateAdded

    var body: some View {
        GeometryReader { geometry in
            let hasDetailColumn = geometry.size.width >= 840
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    toolbar(hasDetailColumn: hasDetailColumn)
                    Divider().overlay(BrowserPalette.border)
                    libraryGrid
                    Divider().overlay(BrowserPalette.border)
                    rotationControls
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if hasDetailColumn {
                    Divider().overlay(BrowserPalette.border)
                    LibraryBrowserDetailView(model: model)
                        .frame(width: 300)
                }
            }
        }
        .foregroundStyle(BrowserPalette.text)
        .background(BrowserPalette.background)
        .tint(BrowserPalette.accent)
        .modifier(LibraryRemovalConfirmation(model: model, isActive: !showsDetails))
        .sheet(isPresented: $showsImport) {
            LibraryImportSheet(model: model)
        }
        .sheet(isPresented: $showsDetails) {
            VStack(spacing: 0) {
                HStack {
                    Text(model.L("library.details")).font(.headline)
                    Spacer()
                    Button(model.L("common.close")) { showsDetails = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding()
                Divider()
                LibraryBrowserDetailView(model: model)
            }
            .frame(width: 400, height: 460)
            .background(BrowserPalette.sidebar)
            .foregroundStyle(BrowserPalette.text)
            .tint(BrowserPalette.accent)
            .modifier(LibraryRemovalConfirmation(model: model))
        }
    }

    private var sortedAssets: [WallpaperAsset] {
        model.libraryAssets.sorted { lhs, rhs in
            if sortOrder == .dateAdded, lhs.dateAdded != rhs.dateAdded {
                return (lhs.dateAdded ?? .distantPast) > (rhs.dateAdded ?? .distantPast)
            }
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    private func toolbar(hasDetailColumn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.L("tab.library")).font(.title2.weight(.semibold))
                Text("\(model.libraryAssets.count)")
                    .font(.callout.monospacedDigit()).foregroundStyle(BrowserPalette.secondary)
                Spacer(minLength: 8)
                HelpPopoverButton(title: model.L("library.help.title"), message: model.L("library.help.body"))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    importButton
                    videoButton
                    Spacer(minLength: 8)
                    sortPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { importButton; videoButton }
                    sortPicker
                }
            }
            HStack(spacing: 8) {
                if !model.selectedLibraryAssetIds.isEmpty {
                    Text(String(format: model.L("library.selection.count"), model.selectedLibraryAssetCount))
                        .font(.caption).foregroundStyle(BrowserPalette.secondary)
                    Spacer(minLength: 4)
                    Button(model.L("library.remove.selected")) { model.requestRemoveSelectedLibraryAssets() }
                        .keyboardShortcut(.delete, modifiers: [])
                        .disabled(model.isWorking)
                } else {
                    Spacer(minLength: 4)
                }
                if !hasDetailColumn {
                    Button { showsDetails = true } label: {
                        Label(model.L("library.details"), systemImage: "sidebar.right")
                    }
                    .disabled(model.selectedLibraryAsset == nil)
                }
            }
            .controlSize(.small)
        }
        .padding(20)
    }

    private var importButton: some View {
        Button { showsImport = true } label: {
            Label(model.L("library.import.local"), systemImage: "folder.badge.plus")
        }
    }

    private var videoButton: some View {
        Button(model.L("library.addVideo")) { model.chooseVideoFile() }
            .disabled(model.isWorking)
    }

    private var sortPicker: some View {
        Picker(model.L("library.sort.title"), selection: $sortOrder) {
            ForEach(ScannedAssetSortOrder.allCases) { order in
                Text(model.L("library.sort.\(order.rawValue)")).tag(order)
            }
        }
        .frame(maxWidth: 190)
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 14)], spacing: 16) {
                ForEach(sortedAssets) { asset in
                    Button { select(asset.id) } label: {
                        LibraryBrowserCard(
                            model: model,
                            asset: asset,
                            isSelected: model.selectedLibraryAssetIds.contains(asset.id),
                            sceneVideoRenderRevision: model.sceneVideoRenderRevision
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(asset.title)
                    .accessibilityAddTraits(model.selectedLibraryAssetIds.contains(asset.id) ? .isSelected : [])
                    .contextMenu { contextMenuItems(for: asset) }
                }
            }
            .padding(20)
        }
        .overlay {
            if model.libraryAssets.isEmpty {
                BrowserEmptyState(
                    symbol: "photo.on.rectangle.angled",
                    title: model.L("library.empty.title"),
                    message: model.L("library.empty.message")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func select(_ id: String) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift),
           let anchor = selectionAnchor ?? model.selectedLibraryAssetId,
           let first = sortedAssets.firstIndex(where: { $0.id == anchor }),
           let last = sortedAssets.firstIndex(where: { $0.id == id }) {
            let range = Set(sortedAssets[min(first, last)...max(first, last)].map(\.id))
            model.selectLibraryAssets(modifiers.contains(.command) ? model.selectedLibraryAssetIds.union(range) : range)
        } else if modifiers.contains(.command) || modifiers.contains(.shift) {
            var selection = model.selectedLibraryAssetIds
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            model.selectLibraryAssets(selection)
            selectionAnchor = id
        } else {
            selectionAnchor = id
            model.selectAndApplyLibraryAsset(id)
        }
    }

    private var rotationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                rotationToggles
                Spacer(minLength: 4)
                rotationTiming
            }
            VStack(alignment: .leading, spacing: 12) {
                rotationToggles
                rotationTiming
            }
        }
        .controlSize(.small)
        .padding(16)
        .background(BrowserPalette.sidebar)
    }

    private var rotationToggles: some View {
        HStack(spacing: 16) {
            Toggle(model.L("library.rotate"), isOn: $model.rotationEnabled)
            Toggle(model.L("library.rotate.shuffle"), isOn: $model.rotationShuffle)
        }
        .toggleStyle(.switch)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var rotationTiming: some View {
        HStack(spacing: 10) {
            Picker(model.L("library.rotate.every"), selection: $model.rotationInterval) {
                ForEach(AppViewModel.rotationIntervalOptions, id: \.seconds) { option in
                    Text(model.L(option.key)).tag(option.seconds)
                }
            }
            .frame(maxWidth: 190)
            Button(model.L("library.rotate.next")) { model.nextWallpaper() }
                .disabled(!model.rotationEnabled)
        }
    }

    @ViewBuilder
    private func contextMenuItems(for asset: WallpaperAsset) -> some View {
        Button(model.L("library.details")) {
            model.selectLibraryAssets([asset.id])
            showsDetails = true
        }
        Button(model.L("library.play")) { model.selectAndApplyLibraryAsset(asset.id) }
            .disabled(asset.supportStatus != .playable)
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
        Button(model.L("library.remove"), role: .destructive) {
            if !model.selectedLibraryAssetIds.contains(asset.id) { model.selectLibraryAssets([asset.id]) }
            model.requestRemoveSelectedLibraryAssets()
        }
        .disabled(model.isWorking)
    }
}

private struct LibraryBrowserCard: View {
    @ObservedObject var model: AppViewModel
    let asset: WallpaperAsset
    let isSelected: Bool
    let sceneVideoRenderRevision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay { BrowserThumbnail(url: libraryThumbnailURL(for: asset)) }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(BrowserPalette.accent, BrowserPalette.sidebar)
                            .font(.title3).padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(BrowserPalette.text)
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)
                Text(model.L("library.kind.\(asset.kind.rawValue)"))
                    .font(.caption).foregroundStyle(BrowserPalette.secondary)
                LibrarySupportBadge(model: model, asset: asset, sceneVideoRenderRevision: sceneVideoRenderRevision)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isSelected ? BrowserPalette.selection : BrowserPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? BrowserPalette.accent : BrowserPalette.border, lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct LibraryRemovalConfirmation: ViewModifier {
    @ObservedObject var model: AppViewModel
    var isActive = true

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.pendingLibraryRemoval.map { String(format: model.L("library.remove.confirm.title"), $0.title) }
                ?? model.L("library.remove.confirm.title.fallback"),
            isPresented: Binding(
                get: { isActive && model.pendingLibraryRemoval != nil },
                set: { if !$0 && isActive { model.cancelPendingLibraryRemoval() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingLibraryRemoval
        ) { _ in
            Button(model.L("library.remove.confirm.button"), role: .destructive) { model.removeSelectedLibraryAssets() }
            Button(model.L("common.cancel"), role: .cancel) { model.cancelPendingLibraryRemoval() }
        } message: { _ in
            Text(model.L("library.remove.confirm.message"))
        }
    }
}
