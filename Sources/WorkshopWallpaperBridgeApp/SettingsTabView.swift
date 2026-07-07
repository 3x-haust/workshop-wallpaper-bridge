import SwiftUI
import WorkshopWallpaperCore

/// The "Settings" tab: playback toggles, audio, Scene Engine assets, Screen
/// Saver, and the Language picker. Long captions are kept to short one-liners
/// with a `HelpPopoverButton` for the full explanation.
struct SettingsTabView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Form {
            Section(model.L("settings.playback.title")) {
                Toggle(model.L("settings.autoPause"), isOn: $model.autoPauseWhenCovered)
                Toggle(model.L("settings.openAtLogin"), isOn: $model.launchAtLogin)
                Toggle(model.L("settings.animateScreenSaver"), isOn: $model.lockScreenAnimationEnabled)
                HStack(spacing: 8) {
                    Toggle(model.L("settings.autoCheckUpdates"), isOn: $model.automaticallyCheckForUpdates)
                    Spacer()
                    Button(model.L("settings.checkUpdates")) {
                        model.checkForUpdates()
                    }
                    .disabled(model.isCheckingForUpdates)
                    if model.availableUpdate != nil {
                        Button(model.L("settings.downloadUpdate")) {
                            model.openAvailableUpdate()
                        }
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    Text(model.L("settings.audio.title"))
                        .font(.subheadline.weight(.semibold))
                    HelpPopoverButton(
                        title: model.L("settings.audio.help.title"),
                        message: model.L("settings.audio.help.body")
                    )
                }
                HStack(spacing: 12) {
                    Toggle(model.L("settings.audio.toggle"), isOn: $model.wallpaperAudioEnabled)
                    Slider(value: $model.wallpaperAudioVolume, in: 0...1)
                        .disabled(!model.wallpaperAudioEnabled)
                        .frame(width: 180)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Text(model.L("settings.scene.title"))
                        .font(.subheadline.weight(.semibold))
                    HelpPopoverButton(
                        title: model.L("settings.scene.help.title"),
                        message: model.L("settings.scene.help.body")
                    )
                }
                Text(model.sceneAssetsStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button(model.L("settings.scene.choose")) {
                        model.chooseSceneAssetsFolder()
                    }
                    if !model.sceneAssetsDirectory.isEmpty {
                        Button(model.L("settings.scene.reset")) {
                            model.clearSceneAssetsFolder()
                        }
                    }
                }
            }

            Section {
                Button(model.L("library.screenSaverSettings")) {
                    model.openScreenSaverSettings()
                }
            }

            Section {
                HStack(spacing: 8) {
                    Text(model.L("settings.language.title"))
                        .font(.subheadline.weight(.semibold))
                    HelpPopoverButton(
                        title: model.L("settings.language.help.title"),
                        message: model.L("settings.language.help.body")
                    )
                    Spacer()
                    Picker(model.L("settings.language.title"), selection: $model.language) {
                        Text(model.L("settings.language.system")).tag(AppLanguage.system)
                        Text(model.L("settings.language.korean")).tag(AppLanguage.korean)
                        Text(model.L("settings.language.english")).tag(AppLanguage.english)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }
        }
        .formStyle(.grouped)
    }
}
