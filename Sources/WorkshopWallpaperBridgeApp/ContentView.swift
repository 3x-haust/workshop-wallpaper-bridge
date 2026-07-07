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
            if model.isWorking {
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

struct AssetRow: View {
    let asset: WallpaperAsset

    // Derived fresh on every body evaluation (not cached in the row) so the
    // badge picks up a completed scene video render as soon as the list
    // re-renders, without needing dedicated per-row observation wiring.
    private var displayStatus: LibraryRowDisplayStatus {
        LibraryRowStatusResolver.status(for: asset)
    }

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
            Text(displayStatus.label)
                .font(.caption)
                .foregroundStyle(displayStatus.isPositive ? .green : .orange)
        }
        .padding(.vertical, 4)
    }
}
