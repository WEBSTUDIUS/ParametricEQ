//  EQSettings.swift
//  ParametricEQ
//
//  Complete EQ state, presets and factory catalogue.
//
//  This is the boundary between the editor and the renderer. Values are
//  normalised here so every downstream consumer sees safe ranges.

import Foundation

/// The complete audible state of the equalizer.
public struct EQSettings: Codable, Equatable, Sendable {
    /// Ordered list of editable bands. The DSP uses the first 16 entries.
    public var bands: [EQBand]
    /// Input gain applied before the filters, in decibels.
    public var preamp: Double
    /// -1 is hard left, +1 is hard right.
    public var balance: Double
    /// A transparent look-ahead limiter protects the output from clipping.
    public var limiter: Bool
    /// Passes audio through untouched while keeping the tap alive.
    public var bypass: Bool

    /// Creates a settings value, normally with the default ten flat bands.
    public init(
        bands: [EQBand] = EQBand.defaultBands(),
        preamp: Double = 0,
        balance: Double = 0,
        limiter: Bool = true,
        bypass: Bool = false
    ) {
        self.bands = bands
        self.preamp = preamp
        self.balance = balance
        self.limiter = limiter
        self.bypass = bypass
    }

    /// Only these keys are persisted; UI-only state lives outside ``EQSettings``.
    private enum CodingKeys: String, CodingKey {
        case bands, preamp, balance, limiter, bypass
    }

    /// Tolerant decoder: missing keys fall back to sensible defaults so older
    /// saved settings keep loading after a schema addition.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bands = try container.decodeIfPresent([EQBand].self, forKey: .bands) ?? EQBand.defaultBands()
        preamp = try container.decodeIfPresent(Double.self, forKey: .preamp) ?? 0
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        limiter = try container.decodeIfPresent(Bool.self, forKey: .limiter) ?? true
        bypass = try container.decodeIfPresent(Bool.self, forKey: .bypass) ?? false
    }

    /// Returns a copy safe for the renderer: non-empty, at most 16 bands
    /// and all values within ``EQBandLimits``.
    public func sanitized() -> EQSettings {
        var copy = self
        if copy.bands.count > EQBandLimits.maxBands {
            copy.bands = Array(copy.bands.prefix(EQBandLimits.maxBands))
        }
        if copy.bands.isEmpty {
            copy.bands = [EQBand()]
        }
        copy.bands = copy.bands.map { $0.normalized() }
        copy.preamp = copy.preamp.clamped(to: EQBandLimits.preamp)
        copy.balance = copy.balance.clamped(to: EQBandLimits.balance)
        return copy
    }

    /// Neutral settings used for first launch, “Reset to Flat” and the
    /// factory Flat preset.
    public static var flat: EQSettings {
        EQSettings(bands: EQBand.defaultBands(), preamp: 0, balance: 0, limiter: true, bypass: false)
    }

    /// Total gain applied by all enabled bands plus the preamp at a frequency.
    public func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        var value = preamp
        for band in bands where band.enabled {
            value += BiquadDesign.coefficients(
                type: band.type,
                frequency: band.frequency,
                gainDB: band.gain,
                q: band.q,
                sampleRate: sampleRate
            ).magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
        return value
    }
}

/// A named snapshot of bands and preamp. Factory presets are immutable;
/// user presets are stored in UserDefaults.
public struct Preset: Identifiable, Codable, Equatable, Sendable {
    /// Stable string identity; factory presets use name-derived IDs.
    public var id: String
    /// Display name shown in the preset menu.
    public var name: String
    /// The bands captured when the preset was saved.
    public var bands: [EQBand]
    /// Preamp captured with the curve.
    public var preamp: Double
    /// Factory presets cannot be deleted or overwritten by the user.
    public var isBuiltIn: Bool

    /// Creates a preset with an explicit identifier.
    public init(
        id: String = UUID().uuidString,
        name: String,
        bands: [EQBand],
        preamp: Double,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bands = bands
        self.preamp = preamp
        self.isBuiltIn = isBuiltIn
    }

    /// Convenience initialiser used by the factory preset builder.
    public init(name: String, settings: EQSettings, isBuiltIn: Bool = false) {
        self.init(
            id: isBuiltIn ? "builtin." + name.lowercased().replacingOccurrences(of: " ", with: "-") : UUID().uuidString,
            name: name,
            bands: settings.bands,
            preamp: settings.preamp,
            isBuiltIn: isBuiltIn
        )
    }

    /// Expands the preset back into full settings; balance, limiter and
    /// bypass intentionally stay at their defaults when applying.
    public var settings: EQSettings {
        EQSettings(bands: bands, preamp: preamp, balance: 0, limiter: true, bypass: false)
    }
}

/// The factory preset catalogue. `all` is a `static let` so band UUIDs
/// remain stable across menu redraws and preset matching.
public enum BuiltInPresets {
    /// All factory presets, built once at process start.
    public static let all: [Preset] = {
        [
            Preset(name: "Flat", settings: .flat, isBuiltIn: true),
            make(
                name: "Warm Low End",
                preamp: -2.5,
                bands: [
                    (.lowShelf, 85, 2.8, 0.7),
                    (.bell, 260, -1.4, 1.1),
                    (.bell, 780, 0.8, 1.4),
                    (.highShelf, 12_000, 0.7, 0.7)
                ]
            ),
            make(
                name: "Vocal Clarity",
                preamp: -2.0,
                bands: [
                    (.highPass, 70, 0, 0.8),
                    (.bell, 240, -2.2, 1.2),
                    (.bell, 2_900, 2.6, 1.0),
                    (.bell, 6_200, 1.5, 1.4),
                    (.highShelf, 11_000, 1.2, 0.7)
                ]
            ),
            make(
                name: "Late Night",
                preamp: -5.0,
                bands: [
                    (.lowShelf, 120, 3.0, 0.7),
                    (.bell, 2_000, -1.6, 1.2),
                    (.highShelf, 7_500, -2.0, 0.7)
                ]
            ),
            make(
                name: "Headphone Air",
                preamp: -2.0,
                bands: [
                    (.bell, 1_900, -1.0, 1.1),
                    (.bell, 3_500, 1.0, 1.2),
                    (.highShelf, 10_000, 2.2, 0.7)
                ]
            )
        ]
    }()

    /// Builds one factory preset from a compact filter tuple list.
    private static func make(
        name: String,
        preamp: Double,
        bands: [(EQFilterType, Double, Double, Double)]
    ) -> Preset {
        let eqBands = bands.map { EQBand(type: $0.0, frequency: $0.1, gain: $0.2, q: $0.3) }
        return Preset(name: name, settings: EQSettings(bands: eqBands, preamp: preamp), isBuiltIn: true)
    }
}
