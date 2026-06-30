import AppKit
import SwiftUI

struct StatusMenu: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Button("Open Settings") {
            SettingsWindowCoordinator.shared.show(model: model)
        }
        Divider()
        Toggle("Open at Login", isOn: $model.launchAtLogin)
        Toggle("Auto-pause Behind Apps", isOn: $model.autoPauseWhenCovered)
        Toggle("Animate Screen Saver", isOn: $model.lockScreenAnimationEnabled)
        Toggle("Auto-check Updates", isOn: $model.automaticallyCheckForUpdates)
        Button("Check for Updates") {
            model.checkForUpdates()
        }
        .disabled(model.isCheckingForUpdates)
        if model.availableUpdate != nil {
            Button("Download Update") {
                model.openAvailableUpdate()
            }
        }
        Button("Open Login Items Settings") {
            model.openLoginItemsSettings()
        }
        Button("Open Screen Saver Settings") {
            model.openScreenSaverSettings()
        }
        Button("Stop Playback") {
            model.stopPlayback()
        }
        Divider()
        Toggle("Rotate Library", isOn: $model.rotationEnabled)
        Toggle("Shuffle Rotation", isOn: $model.rotationShuffle)
        Button("Next Wallpaper") {
            model.nextWallpaper()
        }
        .disabled(!model.rotationEnabled)
        Picker("Rotate Every", selection: $model.rotationInterval) {
            ForEach(AppViewModel.rotationIntervalOptions, id: \.seconds) { option in
                Text(option.label).tag(option.seconds)
            }
        }
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
