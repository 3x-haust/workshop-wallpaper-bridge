import SwiftUI
import WorkshopWallpaperCore

struct LibraryImportSheet: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.L("library.import.local")).font(.title3.weight(.semibold))
                HelpPopoverButton(title: model.L("library.import.help.title"), message: model.L("library.import.help.body"))
                Spacer()
                Button(model.L("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            BrowserSectionLabel(title: model.L("library.source.title"))
            HStack(spacing: 8) {
                TextField(model.L("library.source.placeholder"), text: $model.sourcePath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !model.isWorking { model.scanSource() } }
                Button(model.L("library.browse")) { model.chooseFolder() }
                    .disabled(model.isWorking)
                Button(model.L("library.scan")) { model.scanSource() }
                    .disabled(model.isWorking)
            }
            HStack {
                Text("\(model.L("library.scanned.empty")) (\(model.scannedAssets.count))")
                    .font(.callout.weight(.medium))
                Spacer()
                Picker(model.L("library.sort.title"), selection: $model.scannedSortOrder) {
                    ForEach(ScannedAssetSortOrder.allCases) { order in
                        Text(model.L("library.sort.\(order.rawValue)")).tag(order)
                    }
                }
                .frame(width: 190)
            }
            List(selection: Binding(
                get: { model.selectedScannedAssetIds },
                set: { model.selectScannedAssets($0) }
            )) {
                ForEach(model.scannedAssets) { asset in
                    HStack(spacing: 10) {
                        BrowserThumbnail(url: libraryThumbnailURL(for: asset), contentMode: .fit)
                            .frame(width: 64, height: 44).clipped()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(model.L("library.kind.\(asset.kind.rawValue)")) · \(model.L("library.support.\(asset.supportStatus.rawValue)"))")
                                .font(.caption).foregroundStyle(BrowserPalette.secondary)
                        }
                        Spacer(minLength: 4)
                        if model.isNewScannedAsset(asset) {
                            Text(model.L("library.new.badge"))
                                .font(.caption2.weight(.bold)).foregroundStyle(BrowserPalette.accent)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(asset.id)
                    .listRowBackground(BrowserPalette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BrowserPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if model.scannedAssets.isEmpty {
                    Text(model.L("library.import.local.help"))
                        .font(.callout).foregroundStyle(BrowserPalette.secondary)
                        .multilineTextAlignment(.center).padding(24)
                }
            }
            if let selected = model.selectedScannedAsset {
                HStack(spacing: 12) {
                    BrowserThumbnail(url: libraryThumbnailURL(for: selected), contentMode: .fit)
                        .frame(width: 80, height: 48).clipped()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.title).font(.callout.weight(.medium)).lineLimit(1)
                        if let issue = selected.issues.first {
                            Text(issue.message).font(.caption).foregroundStyle(BrowserPalette.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 12) {
                if let progress = model.importProgress {
                    ProgressView(value: progress.fraction).frame(width: 90)
                } else if model.isWorking {
                    ProgressView().controlSize(.small)
                }
                Text(model.status).font(.caption).foregroundStyle(BrowserPalette.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button(importTitle) { model.importSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedScannedAssetIds.isEmpty || model.isWorking)
            }
        }
        .padding(20)
        .frame(width: 560, height: 460)
        .background(BrowserPalette.background)
        .foregroundStyle(BrowserPalette.text)
        .tint(BrowserPalette.accent)
    }

    private var importTitle: String {
        model.selectedScannedAssetCount > 1
            ? "\(model.L("library.import")) (\(model.selectedScannedAssetCount))"
            : model.L("library.import")
    }
}
