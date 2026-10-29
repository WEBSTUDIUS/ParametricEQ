//  SystemAudioEngine.swift
//  ParametricEQ
//
//  System-audio capture engine: process tap, aggregate device and IOProc.
//
//  Setup/teardown runs on a serial control queue so the TCC prompt or a slow
//  device cannot freeze the UI. The render callback lives on `ioQueue`.

import Foundation
import CoreAudio
import os
import EQCore

/// Opt-in diagnostics for audio bring-up. Enabled with `--diagnostics`;
/// writes to stderr and `/tmp/parametric-eq.log` without touching audio state.
enum Diagnostics {
    /// True when the process was launched with `--diagnostics`.
    static let isEnabled = CommandLine.arguments.contains("--diagnostics")

    /// Writes one timestamp-free diagnostic line to stderr and the log file.
    /// Safe to call from the control queue, never from the render thread.
    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "[ParametricEQ] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/parametric-eq.log")
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// All recoverable failures of the tap/aggregate/IOProc setup, with
/// user-facing descriptions and Core Audio status codes.
enum SystemAudioEngineError: LocalizedError {
    case unsupportedSystem
    case noOutputDevice
    case noDeviceUID
    case noTapFormat
    case unsupportedFormat
    case cannotIdentifyOwnProcess
    case tapCreation(OSStatus)
    case aggregateCreation(OSStatus)
    case ioProcCreation(OSStatus)
    case deviceStart(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "System audio capture requires macOS 14.2 or newer."
        case .noOutputDevice:
            return "No audio output device is available."
        case .noDeviceUID:
            return "The current output device has no persistent identifier."
        case .noTapFormat:
            return "The system audio tap did not report a usable format."
        case .unsupportedFormat:
            return "The current output device does not use 32-bit floating point audio."
        case .cannotIdentifyOwnProcess:
            return "Parametric EQ could not identify its own audio process, so a feedback-safe tap could not be created."
        case let .tapCreation(status):
            return Self.permissionHint(status: status)
        case let .aggregateCreation(status):
            return "The system audio device could not be created (error \(status)). Try selecting a different output device."
        case let .ioProcCreation(status):
            return "The audio renderer could not be attached (error \(status))."
        case let .deviceStart(status):
            return "The audio device could not be started (error \(status)). Try selecting a different output device."
        }
    }

    /// Maps the common TCC/HAL failure codes to actionable permission copy.
    private static func permissionHint(status: OSStatus) -> String {
        if status == -4 || status == kAudioHardwareIllegalOperationError {
            return "System audio access was denied. Open System Settings → Privacy & Security → Screen & System Audio Recording, enable Parametric EQ, then try again."
        }
        return "The system audio tap could not be created (error \(status)). This usually means system audio recording permission is not granted. Open System Settings → Privacy & Security → Screen & System Audio Recording and enable Parametric EQ."
    }
}

/// Owns the process tap, the private aggregate device, the IOProc and the DSP.
///
/// Starting the tap can block while macOS shows the System Audio Recording
/// permission prompt, so all Core Audio setup happens on a control queue while
/// the UI remains responsive.
final class SystemAudioEngine: @unchecked Sendable {
    /// Unified-log logger; the app’s normal diagnostic trail.
    private let logger = Logger(subsystem: "com.andreyilin.ParametricEQ", category: "audio")
    /// Serial queue used by `AudioDeviceCreateIOProcIDWithBlock`. The block is
    /// called on this queue; it must never touch the UI.
    private let ioQueue = DispatchQueue(label: "com.andreyilin.ParametricEQ.io", qos: .userInteractive)
    /// Serial queue for all slow Core Audio setup/teardown. Keeping this off
    /// main lets the TCC prompt block without freezing the window.
    private let controlQueue = DispatchQueue(label: "com.andreyilin.ParametricEQ.control", qos: .userInitiated)
    /// Guards `generation` and `stopRequested` across main and control queues.
    private let operationLock = NSLock()

    /// The DSP renderer shared with the UI.
    let processor = EQProcessor()
    /// Mono ring buffer consumed by the spectrum analyzer.
    let capture = SpectrumCapture()

    /// Latest lifecycle state, published to the UI on the main thread.
    private(set) var state: AudioEngineState = .idle
    /// Active sample rate/channel/device metadata. Nil while stopped.
    private(set) var format: AudioEngineFormat?

    /// Called on the main thread whenever ``state`` changes.
    var onStateChange: ((AudioEngineState) -> Void)?
    /// Called on the main thread when the active format appears/disappears.
    var onFormatChange: ((AudioEngineFormat?) -> Void)?

    /// Core Audio object id of the process tap.
    private var tapID = AudioObjectID.unknown
    /// Private aggregate device that combines the tap and the output device.
    private var aggregateID = AudioObjectID.unknown
    /// Registered render callback; nil while stopped.
    private var ioProcID: AudioDeviceIOProcID?
    /// UUID used in the aggregate description.
    private var tapUUID: UUID?
    /// Last settings requested by the UI; applied again after a device restart.
    private var currentSettings = EQSettings.flat
    /// Sample rate of the active aggregate, used when publishing new settings.
    private var currentSampleRate: Double = 48_000
    /// Listener block for default-output changes; removed before restart.
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    /// Debounced device-change restart work item.
    private var pendingRestart: DispatchWorkItem?
    /// Token that invalidates a scheduled restart if the user turns audio off.
    private var restartToken: UUID?
    /// Monotonic operation id; stale async starts compare against it.
    private var generation = 0
    /// Set by ``stop()`` so an in-flight start aborts at the next checkpoint.
    private var stopRequested = false

    /// Best-effort cleanup if the engine is deallocated without ``stop()``.
    deinit {
        pendingRestart?.cancel()
        removeDefaultDeviceListener()
        teardownAudioObjects()
    }

    // MARK: - Public control

    /// Starts the system tap. Publishes `.starting` immediately, then performs
    /// all Core Audio work on ``controlQueue``. A stale completion is ignored
    /// through the generation counter, and a stop request cancels the start.
    func start(settings: EQSettings) {
        guard !state.isRunning, !state.isStarting else { return }
        let sanitized = settings.sanitized()
        currentSettings = sanitized

        operationLock.lock()
        generation += 1
        let operation = generation
        stopRequested = false
        operationLock.unlock()

        publish(.starting)
        controlQueue.async { [weak self] in
            self?.performStart(settings: sanitized, operation: operation)
        }
    }

    /// Stops audio immediately from the UI’s point of view and queues
    /// teardown/reset on the control queue. Safe to call while a start is
    /// blocked on the TCC prompt; the start will detect the new generation.
    func stop() {
        pendingRestart?.cancel()
        pendingRestart = nil
        restartToken = nil

        operationLock.lock()
        generation += 1
        stopRequested = true
        operationLock.unlock()

        publish(.idle)
        format = nil
        onFormatChange?(nil)

        controlQueue.async { [weak self] in
            self?.teardownAudioObjects()
            self?.processor.reset()
            self?.capture.reset()
        }
    }

    /// Publishes new UI settings to the renderer. Called on every slider/drag
    /// change; the DSP lock makes this cheap and non-blocking.
    func update(settings: EQSettings) {
        currentSettings = settings.sanitized()
        processor.update(settings: currentSettings, sampleRate: currentSampleRate)
    }

    // MARK: - Start / stop internals

    /// Internal sentinel thrown when a newer operation supersedes this start.
    private struct StartCancelled: Error {}

    /// Control-queue half of ``start(settings:)``. Calls ``startInternal``, then
    /// publishes `.running` on main only if the operation is still current.
    /// Failures are converted to `.failed(message)` and fully torn down.
    private func performStart(settings: EQSettings, operation: Int) {
        guard isCurrent(operation) else { return }

        do {
            let info = try startInternal(settings: settings, operation: operation)
            guard isCurrent(operation) else {
                teardownAudioObjects()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(operation) else { return }
                self.currentSampleRate = info.sampleRate
                self.format = info
                self.onFormatChange?(info)
                self.publish(.running)
                self.logger.info("Engine running at \(info.sampleRate, privacy: .public) Hz on \(info.deviceName, privacy: .public)")
            }
        } catch is StartCancelled {
            Diagnostics.log("start cancelled")
            teardownAudioObjects()
        } catch {
            teardownAudioObjects()
            processor.reset()
            capture.reset()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Diagnostics.log("start failed: \(message)")
            logger.error("Engine start failed: \(message, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(operation) else { return }
                self.format = nil
                self.onFormatChange?(nil)
                self.publish(.failed(message))
            }
        }
    }

    /// Builds the complete audio graph in order:
    /// 1. default output device + UID;
    /// 2. global process tap excluding this app;
    /// 3. private aggregate device;
    /// 4. validate 32-bit float formats and sample rate;
    /// 5. prepare the DSP;
    /// 6. install the IOProc;
    /// 7. start the device and observe default-output changes.
    /// Throws ``SystemAudioEngineError`` or ``StartCancelled``.
    private func startInternal(settings: EQSettings, operation: Int) throws -> AudioEngineFormat {
        guard #available(macOS 14.2, *) else { throw SystemAudioEngineError.unsupportedSystem }
        Diagnostics.log("startInternal begin")

        removeDefaultDeviceListener()
        teardownAudioObjects()
        try checkCurrent(operation)

        guard let outputDevice = AudioObjectReader.defaultOutputDevice() else {
            throw SystemAudioEngineError.noOutputDevice
        }
        guard let outputUID = AudioObjectReader.deviceUID(outputDevice) else {
            throw SystemAudioEngineError.noDeviceUID
        }
        let outputDeviceName = AudioObjectReader.deviceName(outputDevice) ?? "System Output"
        Diagnostics.log("output device=\(outputDeviceName) uid=\(outputUID)")

        // Prefer a description that excludes this app by process object. On
        // macOS 26 a bundle-id fallback covers the case where the process
        // object does not exist yet.
        let candidates = try makeTapDescriptions()
        var newTapID = AudioObjectID.unknown
        var uuid = UUID()
        var lastTapStatus: OSStatus = -1

        for description in candidates {
            uuid = description.uuid
            newTapID = .unknown
            let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
            Diagnostics.log("create tap status=\(tapStatus) id=\(newTapID)")
            if tapStatus == noErr, newTapID.isValid {
                lastTapStatus = noErr
                break
            }
            lastTapStatus = tapStatus
            // A denied permission will be denied for every candidate; don't
            // provoke a second system prompt.
            if tapStatus == -4 || tapStatus == kAudioHardwareIllegalOperationError {
                break
            }
        }

        guard lastTapStatus == noErr, newTapID.isValid else {
            logger.error("AudioHardwareCreateProcessTap failed: \(lastTapStatus, privacy: .public)")
            throw SystemAudioEngineError.tapCreation(lastTapStatus)
        }
        tapID = newTapID
        tapUUID = uuid
        try checkCurrent(operation)

        // The aggregate is anchored to the real output device (clock source)
        // and carries the tap as a sub-tap. It is private, so it never shows
        // up as a user-selectable output device.
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Parametric EQ",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateID = AudioObjectID.unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &newAggregateID
        )
        Diagnostics.log("create aggregate status=\(aggregateStatus) id=\(newAggregateID)")
        guard aggregateStatus == noErr, newAggregateID.isValid else {
            logger.error("AudioHardwareCreateAggregateDevice failed: \(aggregateStatus, privacy: .public)")
            throw SystemAudioEngineError.aggregateCreation(aggregateStatus)
        }
        aggregateID = newAggregateID
        try checkCurrent(operation)

        // The aggregate may resample the tap to the output device rate. Ask
        // the aggregate for its actual input/output formats and use those for
        // both DSP design and the renderer.
        let tapFormat = AudioObjectReader.tapFormat(tapID)
        let inputFormat = AudioObjectReader.streamFormat(aggregateID, scope: kAudioObjectPropertyScopeInput) ?? tapFormat
        let outputFormat = AudioObjectReader.streamFormat(aggregateID, scope: kAudioObjectPropertyScopeOutput)

        guard let inputFormat, let outputFormat else {
            Diagnostics.log("missing formats tap=\(String(describing: tapFormat)) in=\(String(describing: inputFormat)) out=\(String(describing: outputFormat))")
            throw SystemAudioEngineError.noTapFormat
        }
        Diagnostics.log("formats in=\(inputFormat.channelCount)ch@\(inputFormat.mSampleRate) out=\(outputFormat.channelCount)ch@\(outputFormat.mSampleRate)")
        guard inputFormat.isFloat32PCM, outputFormat.isFloat32PCM else {
            logger.error("Unsupported formats input=\(String(describing: inputFormat), privacy: .public) output=\(String(describing: outputFormat), privacy: .public)")
            throw SystemAudioEngineError.unsupportedFormat
        }

        let aggregateRate = AudioObjectReader.nominalSampleRate(aggregateID) ?? outputFormat.mSampleRate
        let sampleRate = aggregateRate > 1_000 ? aggregateRate : outputFormat.mSampleRate

        processor.prepare(sampleRate: sampleRate)
        processor.update(settings: settings, sampleRate: sampleRate)
        processor.reset()

        let renderer = AudioRenderer(
            processor: processor,
            capture: capture,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        )
        Diagnostics.log("renderer ready")

        // The IO block runs on `ioQueue`; it only touches preallocated
        // renderer state and never calls back into the UI.
        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            aggregateID,
            ioQueue
        ) { _, inputData, _, outputData, _ in
            renderer.render(inputData: inputData, outputData: outputData)
        }
        Diagnostics.log("create ioproc status=\(ioStatus)")
        guard ioStatus == noErr, let newIOProcID else {
            logger.error("AudioDeviceCreateIOProcIDWithBlock failed: \(ioStatus, privacy: .public)")
            throw SystemAudioEngineError.ioProcCreation(ioStatus)
        }
        ioProcID = newIOProcID
        Diagnostics.log("checking current")
        try checkCurrent(operation)
        Diagnostics.log("current ok; starting device")

        // Starting the aggregate activates the tap. With `.mutedWhenTapped`,
        // the original app audio is muted for as long as we read the tap.
        Diagnostics.log("aggregate=\(aggregateID) rate=\(sampleRate) in=\(inputFormat.channelCount)ch out=\(outputFormat.channelCount)ch")
        let startStatus = AudioDeviceStart(aggregateID, newIOProcID)
        Diagnostics.log("AudioDeviceStart status=\(startStatus)")
        guard startStatus == noErr else {
            logger.error("AudioDeviceStart failed: \(startStatus, privacy: .public)")
            throw SystemAudioEngineError.deviceStart(startStatus)
        }

        installDefaultDeviceListener()
        return AudioEngineFormat(
            sampleRate: sampleRate,
            inputChannels: inputFormat.channelCount,
            outputChannels: outputFormat.channelCount,
            deviceName: outputDeviceName,
            latencyFrames: processor.latencyFrames
        )
    }

    /// Builds the tap description(s). The preferred form excludes this app
    /// by process object; on macOS 26 a bundle-id fallback is used when the
    /// process object is not available. `isExclusive` is intentionally not
    /// touched after the excluding initializer.
    private func makeTapDescriptions() throws -> [CATapDescription] {
        let bundleID = Bundle.main.bundleIdentifier
        let ownProcess = AudioObjectReader.processObject(for: getpid())
        var descriptions: [CATapDescription] = []

        Diagnostics.log("bundle=\(bundleID ?? "nil") ownProcess=\(String(describing: ownProcess))")
        if let ownProcess {
            descriptions.append(CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess]))
        } else if #available(macOS 26.0, *),
                  let bundleID,
                  !bundleID.isEmpty {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.bundleIDs = [bundleID]
            descriptions.append(description)
        }

        guard !descriptions.isEmpty else {
            throw SystemAudioEngineError.cannotIdentifyOwnProcess
        }

        for description in descriptions {
            description.uuid = UUID()
            description.name = "Parametric EQ System Audio"
            description.isMono = false
            description.isMixdown = true
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
        }
        return descriptions
    }

    /// Stops and destroys the IOProc, aggregate and tap in the required order.
    /// Called from the control queue and from deinit.
    private func teardownAudioObjects() {
        removeDefaultDeviceListener()

        if aggregateID.isValid {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }

        if tapID.isValid {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = .unknown
        }
        tapUUID = nil
    }

    /// Throws ``StartCancelled`` if a newer start/stop superseded this one.
    private func checkCurrent(_ operation: Int) throws {
        guard isCurrent(operation) else { throw StartCancelled() }
    }

    /// Thread-safe check of generation and stop flag.
    private func isCurrent(_ operation: Int) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return generation == operation && !stopRequested
    }

    // MARK: - Default output tracking

    /// Observes `kAudioHardwarePropertyDefaultOutputDevice` so the graph can be
    /// rebuilt when headphones or another output device are selected.
    private func installDefaultDeviceListener() {
        removeDefaultDeviceListener()
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestartForDeviceChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system,
            &address,
            DispatchQueue.main,
            listener
        )
        if status == noErr {
            defaultDeviceListener = listener
        } else {
            logger.warning("Could not observe default output device: \(status, privacy: .public)")
        }
    }

    /// Removes the listener, if installed.
    private func removeDefaultDeviceListener() {
        guard let listener = defaultDeviceListener else { return }
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID.system,
            &address,
            DispatchQueue.main,
            listener
        )
        defaultDeviceListener = nil
    }

    /// Debounces output-device notifications, stops the current graph and
    /// starts a new one. A restart token prevents a queued restart from
    /// overriding a manual power-off.
    private func scheduleRestartForDeviceChange() {
        guard state.isRunning else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.isRunning else { return }
            self.logger.info("Default output changed; restarting the tap")
            let settings = self.currentSettings
            self.stop()
            let token = UUID()
            self.restartToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.restartToken == token else { return }
                self.restartToken = nil
                self.start(settings: settings)
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: - Callbacks

    /// Publishes state on main, dispatching if called from the control queue.
    private func publish(_ newState: AudioEngineState) {
        if Thread.isMainThread {
            state = newState
            onStateChange?(newState)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.state = newState
                self?.onStateChange?(newState)
            }
        }
    }
}
