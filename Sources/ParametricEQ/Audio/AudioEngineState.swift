//  AudioEngineState.swift
//  ParametricEQ
//
//  Small value types describing engine lifecycle and active format.

import Foundation

/// Lifecycle of the system-audio engine as observed by the UI.
enum AudioEngineState: Equatable {
    case idle
    case starting
    case running
    case failed(String)

    /// True only when the aggregate device is started and callbacks are live.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// True while tap/aggregate/IOProc setup is in flight on the control queue.
    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    /// Human-readable failure text for the graph overlay and menu bar.
    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }

    /// Compact status used in the header (`OFF`, `LIVE`, …).
    var shortLabel: String {
        switch self {
        case .idle: return "OFF"
        case .starting: return "STARTING"
        case .running: return "LIVE"
        case .failed: return "ERROR"
        }
    }
}

/// Facts about the active audio path, shown in the footer and used
/// by the response graph to design filters at the real sample rate.
struct AudioEngineFormat: Equatable {
    var sampleRate: Double
    var inputChannels: Int
    var outputChannels: Int
    var deviceName: String
    var latencyFrames: Int

    /// Formatted sample rate, e.g. `48.0 kHz`.
    var sampleRateLabel: String {
        String(format: "%.1f kHz", sampleRate / 1_000)
    }
}
