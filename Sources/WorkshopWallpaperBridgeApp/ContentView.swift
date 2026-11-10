import SwiftUI

private enum SettingsTab: CaseIterable, Hashable {
    case workshop, library, settings

    var titleKey: String {
        switch self {
        case .workshop: "workshop.browser.explore"
        case .library: "tab.library"
        case .settings: "tab.settings"
        }
    }

    var symbol: String {
        switch self {
        case .workshop: "safari"
        case .library: "photo.on.rectangle"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject private var workshop: WorkshopViewModel
    @State private var selectedTab: SettingsTab = .workshop
    @State private var showsAccount = false

    init(model: AppViewModel) {
        self.model = model
        self.workshop = model.workshop
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar(compact: geometry.size.width < 900)
                Rectangle().fill(BrowserPalette.border).frame(width: 1)
                page.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(BrowserPalette.background)
        .foregroundStyle(BrowserPalette.text)
        .preferredColorScheme(.dark)
        .tint(BrowserPalette.accent)
        .sheet(isPresented: $showsAccount) {
            WorkshopAuthenticationView(model: model, workshop: workshop)
        }
        .alert(item: $model.updateAlert) { alert in updateAlert(alert) }
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .workshop:
            WorkshopTabView(model: model, workshop: workshop, showsAccount: $showsAccount)
        case .library:
            LibraryTabView(model: model)
        case .settings:
            SettingsTabView(model: model)
        }
    }

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(BrowserPalette.accent)
                if !compact {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Workshop").font(.system(size: 14, weight: .semibold))
                        Text("Wallpaper Bridge").font(.system(size: 10)).foregroundStyle(BrowserPalette.secondary)
                    }
                }
            }
            .padding(.horizontal, 7).padding(.top, 24).padding(.bottom, 24)
            ForEach(SettingsTab.allCases.filter { $0 != .settings }, id: \.self) { tab in
                navigationButton(tab, compact: compact)
            }
            Spacer(minLength: 20)
            navigationButton(.settings, compact: compact)
            Rectangle().fill(BrowserPalette.border).frame(height: 1).padding(.vertical, 8)
            Button { showsAccount = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: workshop.isAuthenticated ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(workshop.isAuthenticated ? BrowserPalette.accent : BrowserPalette.secondary)
                    if !compact {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workshop.account ?? model.L("workshop.browser.connect"))
                                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(model.L(workshop.isAuthenticated ? "workshop.browser.connected" : "workshop.browser.signInRequired"))
                                .font(.system(size: 10)).foregroundStyle(BrowserPalette.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(model.L("workshop.browser.account"))
            .help(model.L("workshop.browser.account"))
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12).frame(width: compact ? 64 : 174)
        .background(BrowserPalette.sidebar)
    }

    private func navigationButton(_ tab: SettingsTab, compact: Bool) -> some View {
        Button { selectedTab = tab } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol).font(.system(size: 15))
                    .frame(width: 18)
                if !compact {
                    Text(model.L(tab.titleKey)).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    if tab == .library, workshop.isBusy {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 0 : 10).padding(.vertical, 11)
            .foregroundStyle(selectedTab == tab ? BrowserPalette.accent : BrowserPalette.secondary)
            .background(selectedTab == tab ? BrowserPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.L(tab.titleKey))
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
        .help(model.L(tab.titleKey))
    }

    private func updateAlert(_ alert: UpdateAlert) -> Alert {
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text(model.L("common.ok")))
        )
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
