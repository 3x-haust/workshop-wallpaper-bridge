import AppKit
import SwiftUI
import WorkshopWallpaperCore

private enum SettingsTab: Hashable {
    case library
    case settings
}

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @State private var selectedTab: SettingsTab = .library

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $selectedTab) {
                LibraryTabView(model: model)
                    .tabItem { Text(model.L("tab.library")) }
                    .tag(SettingsTab.library)
                SettingsTabView(model: model)
                    .tabItem { Text(model.L("tab.settings")) }
                    .tag(SettingsTab.settings)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 640, minHeight: 560)
        .alert(item: $model.updateAlert) { alert in
            updateAlert(alert)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.L("app.title"))
                    .font(.title3.weight(.semibold))
                Text(model.L("app.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(model.L("app.stop")) {
                model.stopPlayback()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        .padding()
    }

    private func updateAlert(_ alert: UpdateAlert) -> Alert {
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text(model.L("common.ok")))
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
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// A small "ⓘ" affordance that reveals a one-time explanation in a popover,
/// used to keep long help/caption text out of the always-visible layout.
struct HelpPopoverButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 300)
        }
    }
}

struct AssetPreview: View {
    let asset: WallpaperAsset?
    let placeholderTitle: String
    let placeholderDescription: String

    var body: some View {
        HStack(spacing: 12) {
            previewImage
            VStack(alignment: .leading, spacing: 4) {
                Text(asset?.title ?? placeholderTitle)
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
            return placeholderDescription
        }
        return "\(asset.kind.rawValue) · \(asset.supportStatus.rawValue)"
    }
}

struct AssetRow: View {
    let asset: WallpaperAsset
    // Unused beyond forcing SwiftUI to re-evaluate this row's body: SwiftUI
    // skips recomputing a child view's body when its stored properties are
    // structurally unchanged, even if the enclosing `@ObservedObject`
    // published an unrelated change. Without a property here that changes
    // when a scene's video render completes, `displayStatus` below would
    // keep returning its first-render value until `asset` itself changed
    // (e.g. on the next library rescan), so the badge would look stuck on
    // "renders on first play" even after the cached video exists.
    let sceneVideoRenderRevision: Int
    var isNew: Bool = false
    var newBadgeText: String = "NEW"

    // Derived fresh on every body evaluation (not cached in the row) so the
    // badge picks up a completed scene video render as soon as the list
    // re-renders, without needing dedicated per-row observation wiring.
    private var displayStatus: LibraryRowDisplayStatus {
        LibraryRowStatusResolver.status(for: asset)
    }

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
            if isNew {
                Text(newBadgeText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
            if let dateAddedText {
                Text(dateAddedText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(asset.kind.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayStatus.label)
                .font(.caption)
                .foregroundStyle(displayStatus.isPositive ? .green : .orange)
        }
        .padding(.vertical, 4)
    }

    private var dateAddedText: String? {
        guard let dateAdded = asset.dateAdded else {
            return nil
        }
        return Self.dateFormatter.string(from: dateAdded)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
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
