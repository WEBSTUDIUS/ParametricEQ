//  HeaderBar.swift
//  ParametricEQ
//
//  Top header, window drag strip and bottom status footer.

import SwiftUI
import AppKit
import EQCore

/// Top chrome: brand mark, preset menu, save/import shortcuts, level meter,
/// status, bypass and power. Also owns the only window-drag strip.
struct HeaderBar: View {
    @ObservedObject var model: AppModel

    /// Name of the preset matching the current curve, or `Custom`.
    private var currentPresetName: String {
        model.activePresetName
    }

    /// Header layout. The background drag area and the 22 px top overlay make
    /// the window movable without stealing drags from the graph.
    var body: some View {
        HStack(spacing: 14) {
            brand
                .padding(.leading, 64)

            Spacer(minLength: 16)

            HStack(spacing: 5) {
                presetMenu
                IconButton(systemName: "square.and.arrow.down", help: "Save current preset") {
                    model.beginSavePreset()
                }
                IconButton(systemName: "square.and.arrow.down.on.square", help: "Import AutoEq preset") {
                    model.beginImport()
                }
                IconButton(systemName: "square.and.arrow.up", help: "Export AutoEq preset") {
                    model.exportCurrentPreset()
                }
            }

            Spacer(minLength: 16)

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Theme.faint.opacity(0.8))
                    LevelMeter(spectrum: model.spectrumModel, width: 50)
                }
                status
                bypassButton
                powerButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(height: 76)
        .background(WindowDragArea())
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: 30, height: 3)
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            // A guaranteed hit-testable strip above the controls. The rest of
            // the window has background dragging disabled so EQ handles and
            // sliders always receive their drags.
            HStack(spacing: 0) {
                Color.clear.frame(width: 80)
                WindowDragArea()
            }
            .frame(height: 22)
        }
    }

    /// Four-bar logo, wordmark and the header drag grip.
    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.9), Theme.cyan.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 29, height: 29)
                    .shadow(color: Theme.accent.opacity(0.28), radius: 8)

                HStack(alignment: .center, spacing: 2.2) {
                    Capsule().fill(Theme.background).frame(width: 2.4, height: 7)
                    Capsule().fill(Theme.background).frame(width: 2.4, height: 13)
                    Capsule().fill(Theme.background).frame(width: 2.4, height: 9)
                    Capsule().fill(Theme.background).frame(width: 2.4, height: 16)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("PARAMETRIC")
                    .font(.system(size: 12.5, weight: .semibold, design: .default))
                    .tracking(2.1)
                    .foregroundStyle(Theme.text)
                Text("SYSTEM EQUALIZER")
                    .font(.system(size: 7.5, weight: .medium, design: .default))
                    .tracking(1.9)
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    /// Factory/user preset picker plus save, import and reset actions.
    private var presetMenu: some View {
        Menu {
            Section("Factory") {
                ForEach(BuiltInPresets.all) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        if model.isPresetSelected(preset) {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }

            if !model.userPresets.isEmpty {
                Section("My Presets") {
                    ForEach(model.userPresets) { preset in
                        Button {
                            model.apply(preset)
                        } label: {
                            if model.isPresetSelected(preset) {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                    Divider()
                    Menu("Delete Preset") {
                        ForEach(model.userPresets) { preset in
                            Button(preset.name, role: .destructive) {
                                model.deletePreset(preset)
                            }
                        }
                    }
                }
            }

            Divider()
            Button {
                model.beginSavePreset()
            } label: {
                Label("Save Current…", systemImage: "square.and.arrow.down")
            }
            Button {
                model.beginImport()
            } label: {
                Label("Import AutoEq…", systemImage: "square.and.arrow.down.on.square")
            }
            Menu {
                Button("Current Curve…") {
                    model.exportCurrentPreset()
                }
                Divider()
                ForEach(model.allPresets) { preset in
                    Button(preset.name) {
                        model.exportPreset(preset)
                    }
                }
            } label: {
                Label("Export AutoEq…", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button {
                model.resetAll()
            } label: {
                Label("Reset to Flat", systemImage: "arrow.counterclockwise")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                Text(currentPresetName)
                    .font(.ui(11.5, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Presets")
    }

    /// Live/off/error dot with sample-rate caption.
    private var status: some View {
        HStack(spacing: 6) {
            StatusDot(state: model.engineState)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.engineState.shortLabel)
                    .font(.mono(8.5, .semibold))
                    .tracking(0.9)
                    .foregroundStyle(model.isRunning ? Theme.green : (model.engineState.errorMessage != nil ? Theme.red : Theme.faint))
                Text(model.sampleRateLabel)
                    .font(.mono(7.5, .regular))
                    .foregroundStyle(Theme.faint)
            }
            .frame(width: 48, alignment: .leading)
        }
    }

    /// Compact dry-pass toggle.
    private var bypassButton: some View {
        Button {
            model.toggleBypass()
        } label: {
            Text("BYPASS")
                .font(.mono(8.5, .semibold))
                .tracking(0.8)
                .foregroundStyle(model.settings.bypass ? Theme.background : (model.isRunning ? Theme.subtext : Theme.faint))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.settings.bypass ? Theme.amber : Color.white.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(model.settings.bypass ? Color.clear : Theme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(model.settings.bypass ? "Disable bypass" : "Bypass equalization")
    }

    /// Master engine power button with a live glow.
    private var powerButton: some View {
        Button {
            model.togglePower()
        } label: {
            ZStack {
                Circle()
                    .fill(model.isRunning ? Theme.accent.opacity(0.14) : Color.white.opacity(0.05))
                    .frame(width: 34, height: 34)
                Circle()
                    .stroke(model.isRunning ? Theme.accent.opacity(0.55) : Theme.stroke, lineWidth: 1)
                    .frame(width: 34, height: 34)
                if model.isRunning {
                    Circle()
                        .fill(Theme.accent.opacity(0.10))
                        .frame(width: 34, height: 34)
                        .blur(radius: 7)
                }
                Image(systemName: "power")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(model.isRunning ? Theme.accent : Theme.subtext)
            }
        }
        .buttonStyle(.plain)
        .help(model.isRunning ? "Turn system audio off" : "Turn system audio on")
    }
}

/// Bottom status strip: output device, sample rate, channel mode, band
/// count, latency and the settings menu.
struct FooterBar: View {
    @ObservedObject var model: AppModel

    /// Footer layout and the gear menu with spectrum/login/reset actions.
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRunning ? Theme.green : Theme.faint)
                    .frame(width: 4, height: 4)
                Text(model.outputDeviceLabel.uppercased())
                    .font(.mono(8, .medium))
                    .tracking(0.7)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }

            Text("·")
                .foregroundStyle(Theme.faint.opacity(0.4))

            Text(model.sampleRateLabel)
                .font(.mono(8, .regular))
                .foregroundStyle(Theme.faint)

            Text("·")
                .foregroundStyle(Theme.faint.opacity(0.4))

            Text("STEREO")
                .font(.mono(8, .regular))
                .foregroundStyle(Theme.faint)

            Spacer()

            Text("\(model.activeBandCount) BANDS")
                .font(.mono(8, .regular))
                .foregroundStyle(Theme.faint)

            Text("·")
                .foregroundStyle(Theme.faint.opacity(0.4))

            Text(latencyLabel)
                .font(.mono(8, .regular))
                .foregroundStyle(Theme.faint)

            Menu {
                Toggle("Show Spectrum", isOn: $model.showSpectrum)
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                Divider()
                Button("Reset to Flat") { model.resetAll() }
                Button("Copy Diagnostics") { copyDiagnostics() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .padding(.top, 2)
        .frame(height: 30)
    }

    /// Formats the look-ahead latency from the active format.
    private var latencyLabel: String {
        let frames = Double(model.format?.latencyFrames ?? 72)
        let rate = max(model.format?.sampleRate ?? 48_000, 1)
        let milliseconds = frames / rate * 1_000
        return String(format: "LOOK-AHEAD %.1f ms", milliseconds)
    }

    /// Copies state/device/settings diagnostics to the clipboard.
    private func copyDiagnostics() {
        let lines = [
            "Parametric EQ 1.0",
            "State: \(model.engineState.shortLabel)",
            "Device: \(model.outputDeviceLabel)",
            "Sample rate: \(model.sampleRateLabel)",
            "Bands: \(model.settings.bands.count)",
            "Bypass: \(model.settings.bypass)",
            "Limiter: \(model.settings.limiter)",
            "Error: \(model.engineState.errorMessage ?? "none")"
        ]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        model.showToast("Diagnostics copied")
    }
}
