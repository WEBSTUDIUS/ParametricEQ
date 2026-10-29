//  AppModel.swift
//  ParametricEQ
//
//  Main-actor application model and persistence layer.
//
//  Owns settings, presets, the audio engine, spectrum state and all UI-facing
//  commands. Views never talk to Core Audio directly.

import Foundation
import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import EQCore

/// The single source of truth for the UI. Owns the user settings, the
/// audio engine, the preset library, the spectrum model and all persistence.
/// Every public method is called on the main actor; the engine handles its own
/// background Core Audio queue internally.
@MainActor
final class AppModel: ObservableObject {
    /// Process-wide singleton shared by the SwiftUI scene and AppDelegate.
    static let shared = AppModel()

    /// Current curve. Every edit immediately updates the renderer and schedules
    /// a debounced save.
    @Published var settings: EQSettings {
        didSet {
            engine.update(settings: settings)
            scheduleSave()
        }
    }

    /// Band selected in the graph, chips and inspector.
    @Published var selectedBandID: UUID?

    /// User-created presets loaded from UserDefaults.
    @Published private(set) var userPresets: [Preset]

    /// Latest engine lifecycle state (mirrors SystemAudioEngine).
    @Published private(set) var engineState: AudioEngineState = .idle

    /// Active audio format shown in the footer.
    @Published private(set) var format: AudioEngineFormat?

    /// Separate observable object so 30 fps spectrum updates do not invalidate
    /// the whole window.
    let spectrumModel = SpectrumModel()

    /// Whether the analyzer is painted behind the response curve.
    @Published var showSpectrum: Bool {
        didSet { UserDefaults.standard.set(showSpectrum, forKey: Keys.showSpectrum) }
    }

    /// Mirror of SMAppService.mainApp.status.
    @Published private(set) var launchAtLogin = false

    /// Set by the watchdog after seven seconds in `.starting`; shows the
    /// permission recovery card.
    @Published private(set) var startupTimedOut = false

    /// Desired engine state persisted across launches.
    @Published private(set) var isEnabled: Bool

    /// Save-preset sheet presentation flag.
    @Published var isShowingSavePreset = false

    /// AutoEq import sheet presentation flag.
    @Published var isShowingImport = false

    /// Name typed into the save sheet.
    @Published var presetNameDraft = ""

    /// Text pasted into the import sheet.
    @Published var importText = ""

    /// Fatal parser error shown inside the import sheet.
    @Published var importError: String?

    /// Transient confirmation message.
    @Published var toast: String?

    /// Controls the first-run welcome card.
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.onboarding) }
    }

    /// The Core Audio engine and its DSP renderer.
    let engine = SystemAudioEngine()

    /// Timer-driven FFT analyzer.
    private let analyzer = SpectrumAnalyzer()
    /// When launched with `--demo`, uses a curated curve and suppresses
    /// persistence (used for screenshots/manual testing).
    private let demoMode = CommandLine.arguments.contains("--demo")
    /// Debounced settings save.
    private var saveWorkItem: DispatchWorkItem?
    /// Auto-dismiss for the toast.
    private var toastWorkItem: DispatchWorkItem?
    /// Shows the permission hint if startup takes too long.
    private var startupWatchdog: DispatchWorkItem?

    /// UserDefaults keys. Version suffixes allow future migrations.
    private enum Keys {
        static let settings = "eq.settings.v1"
        static let presets = "eq.userPresets.v1"
        static let showSpectrum = "ui.showSpectrum"
        static let onboarding = "ui.onboardingComplete"
        static let enabled = "audio.enabled"
    }

    /// Loads persisted state, wires engine/analyzer callbacks and optionally
    /// auto-starts the engine (or demo mode) after the window appears.
    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.settings),
           let decoded = try? JSONDecoder().decode(EQSettings.self, from: data) {
            settings = decoded.sanitized()
        } else {
            settings = .flat
        }
        showSpectrum = UserDefaults.standard.object(forKey: Keys.showSpectrum) as? Bool ?? true
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.onboarding)
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        userPresets = Self.loadUserPresets()
        if demoMode {
            settings = Self.demoSettings
            hasCompletedOnboarding = true
        }
        selectedBandID = settings.bands.first?.id

        engine.onStateChange = { [weak self] state in
            self?.handleEngineState(state)
        }
        engine.onFormatChange = { [weak self] format in
            self?.format = format
            if let rate = format?.sampleRate {
                self?.analyzer.setSampleRate(rate)
            }
        }
        analyzer.onUpdate = { [weak self] values, level in
            self?.spectrumModel.values = values
            self?.spectrumModel.level = level
        }

        refreshLaunchAtLogin()
        if isEnabled || demoMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.startEngine()
            }
        }
    }

    // MARK: - Derived state

    /// The currently selected band, resolved by UUID.
    var selectedBand: EQBand? {
        guard let selectedBandID else { return nil }
        return settings.bands.first { $0.id == selectedBandID }
    }

    /// Index of the selected band in the ordered array.
    var selectedBandIndex: Int? {
        guard let selectedBandID else { return nil }
        return settings.bands.firstIndex { $0.id == selectedBandID }
    }

    /// Convenience mirrors used by the views.
    var isRunning: Bool { engineState.isRunning }
    /// True while the engine is connecting.
    var isStarting: Bool { engineState.isStarting }
    /// True while the dry pass-through is active.
    var isBypassed: Bool { settings.bypass }

    /// Long status string for the menu bar.
    var statusText: String {
        switch engineState {
        case .idle: return "System audio is off"
        case .starting: return "Connecting to system audio…"
        case .running: return "Processing all system audio"
        case .failed: return "Audio access needs attention"
        }
    }

    /// Formatted sample rate or an em dash while stopped.
    var sampleRateLabel: String {
        format?.sampleRateLabel ?? "—"
    }

    /// Current output device name for the footer.
    var outputDeviceLabel: String {
        format?.deviceName ?? "System output"
    }

    /// Number of enabled bands, shown in the graph badge and footer.
    var activeBandCount: Int {
        settings.bands.filter { $0.enabled }.count
    }

    /// Factory presets followed by user presets.
    var allPresets: [Preset] {
        BuiltInPresets.all + userPresets
    }

    /// Name of the factory/user preset matching the current curve, or `Custom`.
    var activePresetName: String {
        allPresets.first(where: { isPresetSelected($0) })?.name ?? "Custom"
    }

    /// Value-based preset matching. Band UUIDs are deliberately ignored so
    /// the Flat factory preset still matches the freshly created default bands.
    func isPresetSelected(_ preset: Preset) -> Bool {
        guard abs(preset.preamp - settings.preamp) < 0.001,
              preset.bands.count == settings.bands.count else { return false }
        for (lhs, rhs) in zip(preset.bands, settings.bands) {
            guard lhs.type == rhs.type,
                  lhs.enabled == rhs.enabled,
                  abs(lhs.frequency - rhs.frequency) < 0.01,
                  abs(lhs.gain - rhs.gain) < 0.01,
                  abs(lhs.q - rhs.q) < 0.001 else { return false }
        }
        return true
    }

    // MARK: - Engine control

    /// Power button/menu action. Starts when off, stops when running or
    /// connecting.
    func togglePower() {
        if isRunning || isStarting {
            disable()
        } else {
            enable()
        }
    }

    /// Persists the desired on-state and asks the engine to start. The call
    /// returns immediately; progress arrives through `handleEngineState`.
    func enable() {
        isEnabled = true
        UserDefaults.standard.set(true, forKey: Keys.enabled)
        startEngine()
    }

    /// Persists the off-state, stops the engine and resets the analyzer.
    func disable() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Keys.enabled)
        startupWatchdog?.cancel()
        startupTimedOut = false
        engine.stop()
        stopAnalyzer()
        withAnimation(.easeOut(duration: 0.2)) {
            hasCompletedOnboarding = true
        }
    }

    /// Stops any in-flight attempt and starts a fresh one; used after granting
    /// permission.
    func retry() {
        engine.stop()
        startEngine()
    }

    /// Marks onboarding complete and requests a start.
    private func startEngine() {
        hasCompletedOnboarding = true
        engine.start(settings: settings)
        if engineState.isRunning {
            startAnalyzer()
        }
    }

    /// Single place where engine transitions update persistence, the analyzer
    /// and the startup watchdog.
    private func handleEngineState(_ state: AudioEngineState) {
        engineState = state
        startupWatchdog?.cancel()
        startupWatchdog = nil
        startupTimedOut = false

        if state.isStarting {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.engineState.isStarting else { return }
                self.startupTimedOut = true
            }
            startupWatchdog = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
        }

        switch state {
        case .running:
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Keys.enabled)
            hasCompletedOnboarding = true
            engine.update(settings: settings)
            startAnalyzer()
        case .failed:
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Keys.enabled)
            stopAnalyzer()
        case .idle, .starting:
            stopAnalyzer()
        }
    }

    /// Starts the FFT timer. Idempotent inside SpectrumAnalyzer.
    private func startAnalyzer() {
        analyzer.start(capture: engine.capture)
    }

    /// Stops the timer and clears the spectrum/level display.
    private func stopAnalyzer() {
        analyzer.stop()
        spectrumModel.values = Array(repeating: 0, count: SpectrumAnalyzer.binCount)
        spectrumModel.level = 0
    }

    /// Opens the System Settings pane that contains the System Audio Recording
    /// toggle.
    func openPrivacySettings() {
        AudioPermission.openSystemSettings()
    }

    // MARK: - Band editing

    /// Selects a band from the graph or chip strip.
    func select(_ bandID: UUID) {
        selectedBandID = bandID
    }

    /// Generic transactional band edit: copies, mutates, normalises and writes
    /// back, triggering the engine update and debounced save exactly once.
    func updateBand(id: UUID, _ update: (inout EQBand) -> Void) {
        guard let index = settings.bands.firstIndex(where: { $0.id == id }) else { return }
        var band = settings.bands[index]
        update(&band)
        settings.bands[index] = band.normalized()
    }

    /// Inspector frequency slider setter.
    func setFrequency(_ value: Double) {
        guard let id = selectedBandID else { return }
        updateBand(id: id) { $0.frequency = value }
    }

    /// Inspector gain slider setter.
    func setGain(_ value: Double) {
        guard let id = selectedBandID else { return }
        updateBand(id: id) { $0.gain = value }
    }

    /// Inspector Q slider setter.
    func setQ(_ value: Double) {
        guard let id = selectedBandID else { return }
        updateBand(id: id) { $0.q = value }
    }

    /// Changes the selected band’s filter shape and zeroes gain for shapes
    /// that do not use it.
    func setType(_ type: EQFilterType) {
        guard let id = selectedBandID else { return }
        updateBand(id: id) { band in
            band.type = type
            if !type.usesGain { band.gain = 0 }
        }
    }

    /// Resets gain to 0 dB and Q to the filter type’s default.
    func resetSelectedBand() {
        guard let id = selectedBandID else { return }
        updateBand(id: id) { band in
            band.gain = 0
            band.q = band.type.defaultQ
        }
    }

    /// Enables/disables the selected band without removing it.
    func toggleSelectedBandEnabled() {
        guard let id = selectedBandID else { return }
        updateBand(id: id) { $0.enabled.toggle() }
    }

    /// Appends a bell at a suggested frequency and selects it.
    func addBand() {
        guard settings.bands.count < EQBandLimits.maxBands else { return }
        let band = EQBand(
            type: .bell,
            frequency: EQBand.suggestedFrequency(after: settings.bands),
            gain: 0,
            q: 1,
            enabled: true
        )
        settings.bands.append(band)
        selectedBandID = band.id
    }

    /// Deletes the selected band while keeping at least one band in the curve.
    func removeSelectedBand() {
        guard settings.bands.count > 1, let id = selectedBandID else { return }
        let index = settings.bands.firstIndex { $0.id == id }
        settings.bands.removeAll { $0.id == id }
        if let index {
            let newIndex = min(index, settings.bands.count - 1)
            selectedBandID = settings.bands[newIndex].id
        } else {
            selectedBandID = settings.bands.first?.id
        }
    }

    /// Chip context-menu/disable action.
    func toggleBandEnabled(_ id: UUID) {
        updateBand(id: id) { $0.enabled.toggle() }
    }

    /// Preamp setter with clamping.
    func setPreamp(_ value: Double) {
        settings.preamp = value.clamped(to: EQBandLimits.preamp)
    }

    /// Stereo balance setter with clamping.
    func setBalance(_ value: Double) {
        settings.balance = value.clamped(to: EQBandLimits.balance)
    }

    /// Toggles the look-ahead limiter.
    func toggleLimiter() {
        settings.limiter.toggle()
    }

    /// Toggles dry pass-through without stopping the tap.
    func toggleBypass() {
        settings.bypass.toggle()
    }

    /// Restores neutral settings and selects the first band.
    func resetAll() {
        settings = .flat
        selectedBandID = settings.bands.first?.id
        showToast("Reset to flat")
    }

    // MARK: - Presets

    /// Applies bands and preamp from a preset; bypass/limiter/balance stay
    /// under user control.
    func apply(_ preset: Preset) {
        settings.bands = preset.bands.map { $0.normalized() }
        settings.preamp = preset.preamp.clamped(to: EQBandLimits.preamp)
        selectedBandID = settings.bands.first?.id
        showToast("Loaded “\(preset.name)”")
    }

    /// Opens the save sheet with a unique suggested name.
    func beginSavePreset() {
        presetNameDraft = suggestedPresetName()
        isShowingSavePreset = true
    }

    /// Validates the name, appends a user preset, persists and closes the sheet.
    func commitSavePreset() {
        let trimmed = presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let name = uniquePresetName(trimmed)
        let preset = Preset(name: name, settings: settings)
        userPresets.append(preset)
        saveUserPresets()
        isShowingSavePreset = false
        showToast("Saved “\(name)”")
    }

    /// Deletes a user preset; factory presets are ignored.
    func deletePreset(_ preset: Preset) {
        guard !preset.isBuiltIn else { return }
        userPresets.removeAll { $0.id == preset.id }
        saveUserPresets()
        showToast("Deleted “\(preset.name)”")
    }

    // MARK: - Export

    /// Exports the current curve to an AutoEq / Equalizer APO text file.
    func exportCurrentPreset() {
        export(settings: settings, suggestedName: activePresetName)
    }

    /// Exports a factory or user preset to an AutoEq / Equalizer APO file.
    func exportPreset(_ preset: Preset) {
        export(settings: preset.settings, suggestedName: preset.name)
    }

    /// Shared NSSavePanel + write path for both export entry points.
    private func export(settings: EQSettings, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Export AutoEq Preset"
        panel.message = "The file can be imported into AutoEq or Equalizer APO."
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFileName(suggestedName) + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = AutoEQExporter.text(for: settings, name: suggestedName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showToast("Exported “\(url.lastPathComponent)”")
        } catch {
            showToast("Export failed: \(error.localizedDescription)")
        }
    }

    /// Keeps a preset name safe as a file name on macOS.
    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let parts = name.components(separatedBy: invalid)
        let cleaned = parts.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Parametric EQ" : cleaned
    }

    /// Base name for a new preset.
    private func suggestedPresetName() -> String {
        let base = "My EQ"
        return uniquePresetName(base)
    }

    /// Appends a numeric suffix until the name is unique across factory and
    /// user presets.
    private func uniquePresetName(_ base: String) -> String {
        let names = Set(allPresets.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Import

    /// Opens a clean AutoEq import sheet.
    func beginImport() {
        importText = ""
        importError = nil
        isShowingImport = true
    }

    /// Shows an NSOpenPanel, parses the selected text file and applies it.
    func importFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Parametric Preset"
        panel.message = "Choose an AutoEq or Equalizer APO parametric preset (.txt)"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try AutoEQParser.parse(fileURL: url)
            applyImport(result)
            isShowingImport = false
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Parses the pasted text and applies it.
    func importFromText() {
        do {
            let result = try AutoEQParser.parse(text: importText, name: "Imported EQ")
            applyImport(result)
            isShowingImport = false
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Applies imported bands/preamp and saves the result as a user preset.
    private func applyImport(_ result: AutoEQImportResult) {
        settings.bands = result.bands.map { $0.normalized() }
        settings.preamp = result.preamp.clamped(to: EQBandLimits.preamp)
        selectedBandID = settings.bands.first?.id

        let name = uniquePresetName(result.name.isEmpty ? "Imported EQ" : result.name)
        let preset = Preset(name: name, settings: settings)
        userPresets.append(preset)
        saveUserPresets()

        if result.warnings.isEmpty {
            showToast("Imported “\(name)”")
        } else {
            showToast(result.warnings.first ?? "Imported with warnings")
        }
    }

    // MARK: - Launch at login

    /// Refreshes the login-item mirror from SMAppService.
    func refreshLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// Registers/unregisters the main app as a login item and reports errors
    /// through a toast.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLogin()
            showToast(enabled ? "Opens at login" : "Login item disabled")
        } catch {
            refreshLaunchAtLogin()
            showToast("Could not update login item: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    /// Debounces settings writes while a slider is being dragged.
    private func scheduleSave() {
        guard !demoMode else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Immediately persists settings and desired on/off state.
    func saveNow() {
        guard !demoMode else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Keys.settings)
        }
        UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
    }

    /// Encodes the user preset array into UserDefaults.
    private func saveUserPresets() {
        guard let data = try? JSONEncoder().encode(userPresets) else { return }
        UserDefaults.standard.set(data, forKey: Keys.presets)
    }

    /// Decodes user presets and drops any built-in entries from old data.
    private static func loadUserPresets() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: Keys.presets),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data) else {
            return []
        }
        return decoded.filter { !$0.isBuiltIn }
    }

    /// Called from AppDelegate termination: flush settings, stop audio and
    /// the analyzer.
    func shutdown() {
        saveWorkItem?.cancel()
        saveNow()
        engine.stop()
        stopAnalyzer()
    }

    // MARK: - Toast

    /// Curated seven-band curve used by `--demo` for screenshots/manual tests.
    private static var demoSettings: EQSettings {
        let bands = [
            EQBand(type: .lowShelf, frequency: 60, gain: 2.2, q: 0.7),
            EQBand(type: .bell, frequency: 180, gain: -1.8, q: 1.1),
            EQBand(type: .bell, frequency: 440, gain: 9.0, q: 1.2),
            EQBand(type: .bell, frequency: 1_200, gain: -2.4, q: 1.4),
            EQBand(type: .bell, frequency: 2_800, gain: 2.6, q: 1.1),
            EQBand(type: .bell, frequency: 5_600, gain: -1.2, q: 1.3),
            EQBand(type: .highShelf, frequency: 10_000, gain: 2.0, q: 0.7)
        ]
        return EQSettings(bands: bands, preamp: -4, balance: 0, limiter: true, bypass: false)
    }

    /// Shows a transient confirmation and schedules its dismissal.
    func showToast(_ message: String) {
        toast = message
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) {
                self?.toast = nil
            }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}

/// Tiny observable container for spectrum bins and peak level. Separating
/// it from AppModel keeps 30 fps updates scoped to the graph.
@MainActor
final class SpectrumModel: ObservableObject {
    @Published var values: [Float] = Array(repeating: 0, count: SpectrumAnalyzer.binCount)
    @Published var level: Float = 0
}
