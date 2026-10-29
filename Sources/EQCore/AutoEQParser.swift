//  AutoEQParser.swift
//  ParametricEQ
//
//  Parser for AutoEq / Equalizer APO parametric text presets.
//
//  Produces normalised bands, preamp and non-fatal warnings.

import Foundation

/// Result of parsing one preset: normalised bands, preamp and any
/// non-fatal warnings suitable for a toast.
public struct AutoEQImportResult: Equatable, Sendable {
    /// Name derived from the file name or supplied by the caller.
    public var name: String
    /// At most ``EQBandLimits/maxBands`` normalised filters.
    public var bands: [EQBand]
    /// Preamp parsed from the `Preamp:` line, clamped to the supported range.
    public var preamp: Double
    /// Human-readable messages for skipped filters or clamped values.
    public var warnings: [String]
}

/// Fatal import errors that should be shown instead of applying a preset.
public enum AutoEQParserError: LocalizedError, Equatable {
    case empty
    case noFilters
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .empty: return "The preset is empty."
        case .noFilters: return "No parametric filters were found in this file."
        case .unreadable: return "The preset could not be read as text."
        }
    }
}

/// Parses the text format exported by AutoEq and Equalizer APO. Only the
/// parametric filter lines and the preamp value are used.
public enum AutoEQParser {
    // Accepts both `Preamp: -6.0 dB` and decimal-comma variants.
    private static let preampRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*Preamp\s*:\s*([-+]?[0-9]+(?:[.,][0-9]+)?)\s*dB"#
    )
    // AutoEq / Equalizer APO filter line. Groups: index, ON/OFF, type,
    // frequency, optional gain and optional Q.
    private static let filterRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*Filter\s*([0-9]+)\s*:\s*(ON|OFF)\s+([A-Za-z]+)\s+Fc\s+([0-9]+(?:[.,][0-9]+)?)\s*Hz(?:\s+Gain\s+([-+]?[0-9]+(?:[.,][0-9]+)?)\s*dB)?(?:\s+Q\s+([0-9]+(?:[.,][0-9]+)?))?"#
    )

    /// Parses AutoEq / Equalizer APO text. Supports decimal dots or commas,
    /// ON/OFF filters, optional gain and Q, and clamps all values before
    /// returning. Throws ``AutoEQParserError`` for empty or unsupported files.
    public static func parse(text: String, name: String = "Imported") throws -> AutoEQImportResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutoEQParserError.empty
        }

        var bands: [EQBand] = []
        var preamp = 0.0
        var warnings: [String] = []
        var unsupported = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)

            // Preamp is global; keep the last one if the file repeats it.
            if let match = preampRegex.firstMatch(in: line, range: range),
               let valueRange = Range(match.range(at: 1), in: line),
               let value = Double(line[valueRange].replacingOccurrences(of: ",", with: ".")) {
                preamp = value
                continue
            }

            if let match = filterRegex.firstMatch(in: line, range: range) {
                guard bands.count < EQBandLimits.maxBands else {
                    warnings.append("Only the first \(EQBandLimits.maxBands) filters were imported.")
                    break
                }

                let enabled = string(in: line, match: match, group: 2)?.uppercased() != "OFF"
                let typeToken = string(in: line, match: match, group: 3)?.uppercased() ?? ""
                guard let type = filterType(from: typeToken) else {
                    unsupported += 1
                    continue
                }
                guard let frequency = double(in: line, match: match, group: 4) else {
                    unsupported += 1
                    continue
                }

                // Missing gain/Q are legal; use musically sensible defaults
                // and clamp everything before it reaches the renderer.
                let gain = double(in: line, match: match, group: 5) ?? 0
                let q = double(in: line, match: match, group: 6) ?? type.defaultQ

                bands.append(
                    EQBand(
                        type: type,
                        frequency: frequency.clamped(to: EQBandLimits.frequency),
                        gain: gain.clamped(to: EQBandLimits.gain),
                        q: q.clamped(to: EQBandLimits.q),
                        enabled: enabled
                    )
                )
                continue
           }

            let lower = line.lowercased()
            if lower.hasPrefix("filter") {
                unsupported += 1
            }
        }

        guard !bands.isEmpty else { throw AutoEQParserError.noFilters }
        if unsupported > 0 {
            warnings.append("Skipped \(unsupported) filter line\(unsupported == 1 ? "" : "s") with an unsupported format.")
        }
        if preamp < -24 || preamp > 12 {
            warnings.append("The preamp was clamped to the supported range.")
            preamp = preamp.clamped(to: EQBandLimits.preamp)
        }

        return AutoEQImportResult(
            name: name,
            bands: bands,
            preamp: preamp,
            warnings: warnings
        )
    }

    /// Reads a UTF-8 text file and delegates to ``parse(text:name:)``.
    public static func parse(fileURL: URL) throws -> AutoEQImportResult {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw AutoEQParserError.unreadable
        }
        return try parse(
            text: text,
            name: fileURL.deletingPathExtension().lastPathComponent
        )
    }

    /// Maps AutoEq type tokens (PK, LS/LSC, HS/HSC, LP, HP, NO, BP)
    /// to the app’s filter enum.
    private static func filterType(from token: String) -> EQFilterType? {
        switch token {
        case "PK", "PEQ", "BELL": return .bell
        case "LS", "LSC", "LOWSHELF": return .lowShelf
        case "HS", "HSC", "HIGHSHELF": return .highShelf
        case "LP", "LPF", "LOWPASS": return .lowPass
        case "HP", "HPF", "HIGHPASS": return .highPass
        case "NO", "NOTCH": return .notch
        case "BP", "BPF", "BANDPASS": return .bandPass
        default: return nil
        }
    }

    /// Extracts one regex capture group as a String.
    private static func string(in line: String, match: NSTextCheckingResult, group: Int) -> String? {
        guard let range = Range(match.range(at: group), in: line) else { return nil }
        return String(line[range])
    }

    /// Extracts one numeric capture group, accepting a decimal comma.
    private static func double(in line: String, match: NSTextCheckingResult, group: Int) -> Double? {
        guard let value = string(in: line, match: match, group: group) else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }
}
