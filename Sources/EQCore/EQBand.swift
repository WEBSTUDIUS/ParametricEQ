//  EQBand.swift
//  ParametricEQ
//
//  Data model for filter types and parametric bands.
//
//  Pure value types shared by the UI, the preset store, the importer and the
//  DSP. No Core Audio or SwiftUI dependencies.

import Foundation

/// The filter shapes supported by the parametric equalizer.
///
/// Each case is rendered by ``BiquadDesign`` as a second-order RBJ
/// section. `usesGain` tells the editor whether the gain control is
/// meaningful; `defaultQ` provides a musical starting point for new bands.
public enum EQFilterType: String, Codable, CaseIterable, Identifiable, Sendable {
    case bell
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch
    case bandPass

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bell: return "Bell"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .notch: return "Notch"
        case .bandPass: return "Band Pass"
        }
    }

    public var shortName: String {
        switch self {
        case .bell: return "BELL"
        case .lowShelf: return "LSH"
        case .highShelf: return "HSH"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .notch: return "NOTCH"
        case .bandPass: return "BP"
        }
    }

    public var symbolName: String {
        switch self {
        case .bell: return "circle.circle"
        case .lowShelf: return "arrow.up.right"
        case .highShelf: return "arrow.down.right"
        case .lowPass: return "water.waves"
        case .highPass: return "wind"
        case .notch: return "minus.circle"
        case .bandPass: return "line.3.horizontal.decrease"
        }
    }

    /// Whether the gain parameter has an effect on this filter shape.
    public var usesGain: Bool {
        switch self {
        case .bell, .lowShelf, .highShelf: return true
        case .lowPass, .highPass, .notch, .bandPass: return false
        }
    }

    /// The Q value a freshly created band of this type should use.
    public var defaultQ: Double {
        switch self {
        case .lowShelf, .highShelf: return 0.7
        case .lowPass, .highPass: return 0.707
        default: return 1.0
        }
    }
}

/// Bounds shared by the editor, importer and DSP so the UI can never
/// produce values the audio renderer cannot handle.
public enum EQBandLimits {
    public static let frequency: ClosedRange<Double> = 10...24_000
    public static let gain: ClosedRange<Double> = -24...24
    public static let q: ClosedRange<Double> = 0.05...20
    public static let preamp: ClosedRange<Double> = -24...12
    public static let balance: ClosedRange<Double> = -1...1
    public static let maxBands = 16
}

/// A single parametric filter.
///
/// The band is a pure value type: the UI edits copies, presets archive
/// copies and the renderer receives a normalised snapshot. The UUID is
/// deliberately outside the DSP state and exists only for SwiftUI and
/// graph hit-testing.
public struct EQBand: Identifiable, Codable, Equatable, Sendable {
    /// Stable identity used by SwiftUI lists and graph hit-testing.
    public var id: UUID
    /// Filter shape. Changing it does not change the stored gain/Q values;
    /// the editor decides which controls are relevant.
    public var type: EQFilterType
    /// Centre frequency for bells/notches or corner frequency for shelves/passes.
    public var frequency: Double
    /// Boost/cut in decibels. Ignored by pass/notch filters.
    public var gain: Double
    /// Quality factor. Higher values mean a narrower bell or a steeper
    /// resonant pass filter; shelves use it as a slope control.
    public var q: Double
    /// Disabled bands are kept in the editor but replaced by an identity
    /// filter in the renderer.
    public var enabled: Bool

    /// Creates a band. All values are normalised later by ``normalized()``,
    /// so callers may pass UI or AutoEq values directly.
    public init(
        id: UUID = UUID(),
        type: EQFilterType = .bell,
        frequency: Double = 1_000,
        gain: Double = 0,
        q: Double = 1,
        enabled: Bool = true
    ) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.enabled = enabled
    }

    /// Clamps every parameter to ``EQBandLimits`` and returns a safe copy.
    /// The renderer and persistence layer only deal with normalised bands.
    public func normalized() -> EQBand {
        var copy = self
        copy.frequency = frequency.clamped(to: EQBandLimits.frequency)
        copy.gain = gain.clamped(to: EQBandLimits.gain)
        copy.q = q.clamped(to: EQBandLimits.q)
        return copy
    }

    /// A short, human readable frequency such as `1.2 kHz`.
    public var frequencyLabel: String {
        Self.formatFrequency(frequency)
    }

    /// Signed gain label used in the UI, e.g. `+3.0 dB`.
    public var gainLabel: String {
        String(format: "%+.1f dB", gain)
    }

    /// Formats a frequency with the most useful precision for its decade.
    public static func formatFrequency(_ value: Double) -> String {
        if value >= 10_000 {
            return String(format: "%.1f kHz", value / 1_000)
        } else if value >= 1_000 {
            return String(format: "%.2f kHz", value / 1_000)
        } else if value >= 100 {
            return String(format: "%.0f Hz", value)
        } else {
            return String(format: "%.1f Hz", value)
        }
    }

    /// Ten neutral filters: a low shelf, eight bells and a high shelf.
    public static func defaultBands() -> [EQBand] {
        let frequencies: [Double] = [32, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
        return frequencies.enumerated().map { index, frequency in
            let type: EQFilterType
            if index == 0 {
                type = .lowShelf
            } else if index == frequencies.count - 1 {
                type = .highShelf
            } else {
                type = .bell
            }
            return EQBand(
                type: type,
                frequency: frequency,
                gain: 0,
                q: type.defaultQ,
                enabled: true
            )
        }
    }

    /// Picks a sensible centre frequency for a new band.
    public static func suggestedFrequency(after bands: [EQBand]) -> Double {
        let sorted = bands.map(\.frequency).sorted()
        guard let highest = sorted.last else { return 1_000 }
        return min(highest * 1.5, 20_000).clamped(to: EQBandLimits.frequency)
    }
}

public extension Comparable {
    /// Small shared utility that keeps sliders, drag gestures and imported
    /// presets inside their declared ranges.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
