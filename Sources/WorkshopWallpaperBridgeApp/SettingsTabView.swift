import SwiftUI
import WorkshopWallpaperCore

struct SettingsTabView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject private var audioAnalysis = SystemAudioAnalysis.shared
    @ObservedObject private var musicMetadata = MusicMetadataSource.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.L("tab.settings"))
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 4)
                playbackSection
                audioSection
                integrationSection
                reactiveAudioSection
                sceneSection
                settingsSection(title: model.L("library.screenSaverSettings")) {
                    Toggle(model.L("settings.animateScreenSaver"), isOn: $model.lockScreenAnimationEnabled)
                    Button(model.L("library.screenSaverSettings")) { model.openScreenSaverSettings() }
                }
                languageSection
                updateSection
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(BrowserPalette.background)
        .foregroundStyle(BrowserPalette.text)
        .tint(BrowserPalette.accent)
        .toggleStyle(.switch)
        .onAppear { audioAnalysis.refreshPermission() }
    }

    private var playbackSection: some View {
        settingsSection(title: model.L("settings.playback.title")) {
            Toggle(model.L("settings.autoPause"), isOn: $model.autoPauseWhenCovered)
            Divider().overlay(BrowserPalette.border)
            Toggle(model.L("settings.liveScenes.toggle"), isOn: $model.preferLiveScenes)
            caption(model.L("settings.liveScenes.help"))
            Divider().overlay(BrowserPalette.border)
            Toggle(model.L("settings.interaction.toggle"), isOn: $model.wallpaperInteractionEnabled)
            caption(model.L("settings.interaction.help"))
            Divider().overlay(BrowserPalette.border)
            Toggle(model.L("settings.openAtLogin"), isOn: $model.launchAtLogin)
        }
    }

    private var audioSection: some View {
        settingsSection(title: model.L("settings.audio.title")) {
            HStack {
                Toggle(model.L("settings.audio.toggle"), isOn: $model.wallpaperAudioEnabled)
                HelpPopoverButton(title: model.L("settings.audio.help.title"), message: model.L("settings.audio.help.body"))
            }
            Slider(value: $model.wallpaperAudioVolume, in: 0...1)
                .disabled(!model.wallpaperAudioEnabled)
                .accessibilityLabel(model.L("settings.audio.title"))
        }
    }

    private var integrationSection: some View {
        settingsSection(title: model.L("settings.media.toggle")) {
            Toggle(model.L("settings.media.toggle"), isOn: $model.mediaIntegrationEnabled)
            caption(model.L("settings.media.help"))
            if !musicMetadata.status.isEmpty { caption(musicMetadata.status) }
        }
    }

    private var reactiveAudioSection: some View {
        settingsSection(title: model.L("settings.audioReactive.toggle")) {
            Toggle(model.L("settings.audioReactive.toggle"), isOn: $model.audioReactiveEnabled)
            caption(model.L("settings.audioReactive.help"))
            if model.audioReactiveEnabled && audioAnalysis.needsPermission {
                caption(model.L("settings.audioReactive.permission"))
                Button(model.L("settings.audioReactive.authorize")) { audioAnalysis.authorize() }
            } else if model.audioReactiveEnabled && !audioAnalysis.status.isEmpty {
                caption(model.L(audioAnalysis.status))
                Button(model.L("settings.audioReactive.retry")) { audioAnalysis.retryCapture() }
            }
        }
    }

    private var sceneSection: some View {
        settingsSection(title: model.L("settings.scene.title")) {
            HStack(alignment: .top, spacing: 8) {
                caption(model.sceneAssetsStatus)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                HelpPopoverButton(title: model.L("settings.scene.help.title"), message: model.L("settings.scene.help.body"))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { sceneButtons }
                VStack(alignment: .leading, spacing: 8) { sceneButtons }
            }
        }
    }

    @ViewBuilder
    private var sceneButtons: some View {
        Button(model.L("settings.scene.choose")) { model.chooseSceneAssetsFolder() }
        if !model.sceneAssetsDirectory.isEmpty {
            Button(model.L("settings.scene.reset")) { model.clearSceneAssetsFolder() }
        }
    }

    private var languageSection: some View {
        settingsSection(title: model.L("settings.language.title")) {
            HStack(alignment: .top, spacing: 8) {
                Picker(model.L("settings.language.title"), selection: $model.language) {
                    Text(model.L("settings.language.system")).tag(AppLanguage.system)
                    Text(model.L("settings.language.korean")).tag(AppLanguage.korean)
                    Text(model.L("settings.language.simplifiedChinese")).tag(AppLanguage.simplifiedChinese)
                    Text(model.L("settings.language.english")).tag(AppLanguage.english)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                HelpPopoverButton(title: model.L("settings.language.help.title"), message: model.L("settings.language.help.body"))
            }
        }
    }

    private var updateSection: some View {
        settingsSection(title: model.L("settings.checkUpdates")) {
            Toggle(model.L("settings.autoCheckUpdates"), isOn: $model.automaticallyCheckForUpdates)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { updateButtons }
                VStack(alignment: .leading, spacing: 8) { updateButtons }
            }
        }
    }

    @ViewBuilder
    private var updateButtons: some View {
        Button(model.L("settings.checkUpdates")) { model.checkForUpdates() }
            .disabled(model.isCheckingForUpdates)
        if model.availableUpdate != nil {
            Button(model.L("settings.downloadUpdate")) { model.openAvailableUpdate() }
        }
    }

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BrowserSectionLabel(title: title)
            VStack(alignment: .leading, spacing: 14, content: content)
                .font(.callout)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BrowserPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(BrowserPalette.border)
                }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(BrowserPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
