//  MenuBarView.swift
//  ParametricEQ
//
//  Contents of the menu-bar status item.

import SwiftUI
import AppKit
import EQCore

/// Menu contents of the status-bar item: engine state, power toggle,
/// bypass, preset submenu, window opener, login item and quit.
struct MenuBarView: View {
    @ObservedObject var model: AppModel

    /// Version shown in the About panel, taken from Info.plist.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
    }

    /// SwiftUI menu items. AppKit renders this as a native menu.
    var body: some View {
        Group {
            Text(model.statusText)

            if let error = model.engineState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    model.openPrivacySettings()
                }
                Button("Retry") {
                    model.retry()
                }
            }

            Divider()

            Button(model.isRunning ? "Turn System Audio Off" : "Turn System Audio On") {
                model.togglePower()
            }

            Toggle("Bypass Equalization", isOn: $model.settings.bypass)

            Menu("Preset") {
                Section("Factory") {
                    ForEach(BuiltInPresets.all) { preset in
                        Button(preset.name) { model.apply(preset) }
                    }
                }
                if !model.userPresets.isEmpty {
                    Section("My Presets") {
                        ForEach(model.userPresets) { preset in
                            Button(preset.name) { model.apply(preset) }
                        }
                    }
                }
            }

            Menu("Export AutoEq") {
                Button("Current Curve…") { model.exportCurrentPreset() }
                Divider()
                ForEach(model.allPresets) { preset in
                    Button(preset.name) { model.exportPreset(preset) }
                }
            }

            Divider()

            Button("Open Parametric EQ") {
                AppDelegate.shared?.showMainWindow()
            }
            .keyboardShortcut("o")

            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            Toggle("Show Spectrum", isOn: $model.showSpectrum)

            Divider()

            Button("About Parametric EQ") {
                NSApp.orderFrontStandardAboutPanel(
                    options: [
                        .applicationName: "Parametric EQ",
                        .applicationVersion: appVersion,
                        .credits: NSAttributedString(string: "System-wide parametric equalizer for macOS.")
                    ]
                )
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit Parametric EQ") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
