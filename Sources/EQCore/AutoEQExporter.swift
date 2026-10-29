//  AutoEQExporter.swift
//  ParametricEQ
//
//  Serialises the current curve to the AutoEq / Equalizer APO text format.

import Foundation

/// Converts ``EQSettings`` or ``Preset`` into a portable parametric text file.
///
/// The output is intentionally conservative: `#` comments, a `Preamp:` line
/// and one `Filter N:` line per band. All numbers use a POSIX decimal point so
/// the file can be imported on machines with a comma decimal separator.
public enum AutoEQExporter {
    /// Serialises the current settings. The name is only used in comments.
    public static func text(for settings: EQSettings, name: String = "Custom") -> String {
        let sanitized = settings.sanitized()
        let cleanName = sanitizeName(name)
        var lines: [String] = [
            "# Parametric EQ preset",
            "# Name: \(cleanName)",
            "# Compatible with AutoEq / Equalizer APO",
            "",
            "Preamp: \(number(sanitized.preamp)) dB"
        ]

        for (index, band) in sanitized.bands.prefix(EQBandLimits.maxBands).enumerated() {
            let state = band.enabled ? "ON" : "OFF"
            let type = filterToken(for: band.type)
            var line = "Filter \(index + 1): \(state) \(type) Fc \(number(band.frequency)) Hz"

            if band.type.usesGain {
                line += " Gain \(number(band.gain)) dB"
            }
            line += " Q \(number(band.q))"
            lines.append(line)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Serialises a saved preset (factory or user).
    public static func text(for preset: Preset) -> String {
        text(for: preset.settings, name: preset.name)
    }

    /// AutoEq token for a filter type.
    public static func filterToken(for type: EQFilterType) -> String {
        switch type {
        case .bell: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .notch: return "NO"
        case .bandPass: return "BP"
        }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func sanitizeName(_ name: String) -> String {
        let singleLine = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.isEmpty ? "Custom" : singleLine
    }
}
