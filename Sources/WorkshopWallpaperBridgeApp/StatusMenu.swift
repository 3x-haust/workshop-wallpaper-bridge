import AppKit
import SwiftUI

struct StatusMenu: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Button(model.L("menu.openSettings")) {
            SettingsWindowCoordinator.shared.show(model: model)
        }
        Divider()
        Toggle(model.L("settings.interaction.toggle"), isOn: $model.wallpaperInteractionEnabled)
        Toggle(model.L("settings.openAtLogin"), isOn: $model.launchAtLogin)
        Toggle(model.L("menu.autoPause"), isOn: $model.autoPauseWhenCovered)
        Toggle(model.L("settings.animateScreenSaver"), isOn: $model.lockScreenAnimationEnabled)
        Toggle(model.L("settings.autoCheckUpdates"), isOn: $model.automaticallyCheckForUpdates)
        Button(model.L("menu.checkForUpdates")) {
            model.checkForUpdates()
        }
        .disabled(model.isCheckingForUpdates)
        if model.availableUpdate != nil {
            Button(model.L("settings.downloadUpdate")) {
                model.openAvailableUpdate()
            }
        }
        Button(model.L("menu.openLoginItems")) {
            model.openLoginItemsSettings()
        }
        Button(model.L("menu.openScreenSaverSettings")) {
            model.openScreenSaverSettings()
        }
        Button(model.L("menu.stopPlayback")) {
            model.stopPlayback()
        }
        Divider()
        Toggle(model.L("library.rotate"), isOn: $model.rotationEnabled)
        Toggle(model.L("menu.shuffleRotation"), isOn: $model.rotationShuffle)
        Button(model.L("menu.nextWallpaper")) {
            model.nextWallpaper()
        }
        .disabled(!model.rotationEnabled)
        Picker(model.L("menu.rotateEvery"), selection: $model.rotationInterval) {
            ForEach(AppViewModel.rotationIntervalOptions, id: \.seconds) { option in
                Text(model.L(option.key)).tag(option.seconds)
            }
        }
        Divider()
        Button(model.L("menu.quit")) {
            NSApp.terminate(nil)
        }
    }
}
