//  main.swift
//  ParametricEQ
//
//  Standalone DSP self-test harness.
//
//  Command Line Tools do not ship XCTest, so this executable performs the same
//  checks with plain asserts and a non-zero exit code on failure.

import Foundation
import EQCore

var failures = 0
var checks = 0

/// Records one assertion. Failures are printed immediately; the process exits
/// non-zero at the end so CI can consume the result without XCTest.
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

/// Convenience assertion for floating-point values with an absolute tolerance.
func close(_ value: Double, _ expected: Double, _ tolerance: Double, _ message: String) {
    check(abs(value - expected) <= tolerance, "\(message) (got \(value), expected \(expected) ± \(tolerance))")
}

/// Offline render helper: prepares a fresh processor, applies settings and
/// processes the entire buffer. Used by the processor checks.
func render(settings: EQSettings, left: [Float], right: [Float], sampleRate: Double = 48_000) -> ([Float], [Float]) {
    var left = left
    var right = right
    let processor = EQProcessor()
    processor.prepare(sampleRate: sampleRate)
    processor.update(settings: settings, sampleRate: sampleRate)
    let count = left.count
    left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
            processor.processPlanar(
                left: leftBuffer.baseAddress!,
                right: rightBuffer.baseAddress!,
                frameCount: count
            )
        }
    }
    return (left, right)
}

/// Generates a mono sine wave used as deterministic test input.
func sine(frequency: Double, amplitude: Double, count: Int, sampleRate: Double = 48_000) -> [Float] {
    (0..<count).map { index in
        Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
    }
}

/// Root-mean-square over a slice, used to compare steady-state gain.
func rms(_ samples: [Float], from: Int, to: Int) -> Double {
    let slice = samples[from..<to]
    let sum = slice.reduce(0.0) { $0 + Double($1 * $1) }
    return sqrt(sum / Double(slice.count))
}

// MARK: - Biquad response

do {
    let sr = 48_000.0
    let bell = BiquadDesign.coefficients(type: .bell, frequency: 1_000, gainDB: 6, q: 1, sampleRate: sr)
    close(bell.magnitudeDB(at: 1_000, sampleRate: sr), 6, 0.05, "bell boost at centre")
    close(bell.magnitudeDB(at: 100, sampleRate: sr), 0, 0.3, "bell boost far below")
    close(bell.magnitudeDB(at: 10_000, sampleRate: sr), 0, 0.3, "bell boost far above")

    let cut = BiquadDesign.coefficients(type: .bell, frequency: 2_500, gainDB: -9, q: 1.4, sampleRate: 44_100)
    close(cut.magnitudeDB(at: 2_500, sampleRate: 44_100), -9, 0.05, "bell cut at centre")

    let lowShelf = BiquadDesign.coefficients(type: .lowShelf, frequency: 100, gainDB: 6, q: 0.7, sampleRate: sr)
    close(lowShelf.magnitudeDB(at: 20, sampleRate: sr), 6, 0.25, "low shelf boost")
    close(lowShelf.magnitudeDB(at: 10_000, sampleRate: sr), 0, 0.15, "low shelf unity")

    let highShelf = BiquadDesign.coefficients(type: .highShelf, frequency: 8_000, gainDB: -6, q: 0.7, sampleRate: sr)
    close(highShelf.magnitudeDB(at: 19_000, sampleRate: sr), -6, 0.25, "high shelf cut")
    close(highShelf.magnitudeDB(at: 100, sampleRate: sr), 0, 0.15, "high shelf unity")

    let hp = BiquadDesign.coefficients(type: .highPass, frequency: 1_000, gainDB: 0, q: 0.707, sampleRate: sr)
    check(hp.magnitudeDB(at: 100, sampleRate: sr) < -35, "high pass rejects lows")
    close(hp.magnitudeDB(at: 10_000, sampleRate: sr), 0, 0.1, "high pass passes highs")

    let lp = BiquadDesign.coefficients(type: .lowPass, frequency: 1_000, gainDB: 0, q: 0.707, sampleRate: sr)
    check(lp.magnitudeDB(at: 15_000, sampleRate: sr) < -40, "low pass rejects highs")
    close(lp.magnitudeDB(at: 50, sampleRate: sr), 0, 0.1, "low pass passes lows")

    for type in EQFilterType.allCases {
        let extreme = BiquadDesign.coefficients(type: type, frequency: 24_000, gainDB: 24, q: 0.05, sampleRate: sr)
        check(extreme.isFinite, "\(type) extreme coefficients are finite")
    }

    close(EQSettings.flat.responseDB(at: 1_000, sampleRate: sr), 0, 0.001, "flat response")
    let cascaded = EQSettings(
        bands: [
            EQBand(type: .bell, frequency: 1_000, gain: 4, q: 1),
            EQBand(type: .bell, frequency: 1_000, gain: 3, q: 1)
        ],
        preamp: -1
    )
    close(cascaded.responseDB(at: 1_000, sampleRate: sr), 6, 0.1, "cascaded response")
}

// MARK: - Processor

do {
    var settings = EQSettings.flat
    settings.limiter = false
    settings.bands = [EQBand(type: .bell, frequency: 1_000, gain: 12, q: 1)]
    let input = sine(frequency: 1_000, amplitude: 0.05, count: 48_000)
    let (left, _) = render(settings: settings, left: input, right: input)
    let measured = rms(left, from: 24_000, to: 48_000)
    let expected = 0.05 * pow(10, 12.0 / 20) / sqrt(2)
    close(measured, expected, expected * 0.02, "processor bell boost")

    var bypassSettings = EQSettings.flat
    bypassSettings.bypass = true
    bypassSettings.limiter = false
    bypassSettings.bands = [EQBand(type: .bell, frequency: 1_000, gain: 18, q: 1)]
    let bypassInput = sine(frequency: 1_000, amplitude: 0.1, count: 8_000)
    let (bypassed, _) = render(settings: bypassSettings, left: bypassInput, right: bypassInput)
    var maxDifference = 0.0
    for index in 2_000..<8_000 {
        maxDifference = max(maxDifference, abs(Double(bypassed[index]) - Double(bypassInput[index - 72])))
    }
    check(maxDifference < 0.002, "processor bypass is transparent (max diff \(maxDifference))")

    var preampSettings = EQSettings.flat
    preampSettings.limiter = false
    preampSettings.preamp = -6
    preampSettings.bands = []
    let preampInput = sine(frequency: 440, amplitude: 0.2, count: 48_000)
    let (preamped, _) = render(settings: preampSettings, left: preampInput, right: preampInput)
    let preampRMS = rms(preamped, from: 24_000, to: 48_000)
    let preampExpected = 0.2 * pow(10, -6.0 / 20) / sqrt(2)
    close(preampRMS, preampExpected, preampExpected * 0.03, "processor preamp")

    var limiterSettings = EQSettings.flat
    limiterSettings.limiter = true
    limiterSettings.preamp = 12
    limiterSettings.bands = []
    let hotInput = sine(frequency: 220, amplitude: 0.8, count: 48_000)
    let (limited, _) = render(settings: limiterSettings, left: hotInput, right: hotInput)
    let peak = limited.map { abs($0) }.max() ?? 0
    check(peak <= 0.951, "limiter ceiling (peak \(peak))")
    check(peak > 0.8, "limiter does not over-attenuate (peak \(peak))")

    var panSettings = EQSettings.flat
    panSettings.limiter = false
    panSettings.balance = -1
    let constant = [Float](repeating: 0.25, count: 4_000)
    let (pannedLeft, pannedRight) = render(settings: panSettings, left: constant, right: constant)
    check(pannedLeft[3_000] > 0.24, "hard left keeps left channel")
    check(abs(pannedRight[3_000]) < 0.001, "hard left silences right channel")

    var disabledSettings = EQSettings.flat
    disabledSettings.limiter = false
    disabledSettings.bands = [EQBand(type: .bell, frequency: 1_000, gain: 18, q: 1, enabled: false)]
    let disabledInput = sine(frequency: 1_000, amplitude: 0.1, count: 24_000)
    let (disabledOutput, _) = render(settings: disabledSettings, left: disabledInput, right: disabledInput)
    close(rms(disabledOutput, from: 12_000, to: 24_000), 0.1 / sqrt(2), 0.001, "disabled band is transparent")
}

// MARK: - Spectrum capture

do {
    let capture = SpectrumCapture()
    let samples = (0..<100).map { Float($0) }
    samples.withUnsafeBufferPointer { buffer in
        capture.append(left: buffer.baseAddress!, right: buffer.baseAddress!, count: samples.count)
    }
    var output = [Float](repeating: 0, count: 10)
    output.withUnsafeMutableBufferPointer { buffer in
        check(capture.readLatest(into: buffer.baseAddress!, count: 10), "spectrum capture read")
    }
    check(output.first == 90 && output.last == 99, "spectrum capture returns newest samples")
}

// MARK: - AutoEQ parser

do {
    let text = """
    Preamp: -6.2 dB
    Filter 1: ON PK Fc 105 Hz Gain 5.5 dB Q 0.70
    Filter 2: ON LSC Fc 80 Hz Gain 2.0 dB Q 0.70
    Filter 3: OFF HSC Fc 10000 Hz Gain -1.5 dB Q 0.70
    Filter 4: ON HP Fc 20 Hz Q 0.707
    """
    let result = try AutoEQParser.parse(text: text, name: "HD 600")
    check(result.name == "HD 600", "AutoEQ name")
    close(result.preamp, -6.2, 0.001, "AutoEQ preamp")
    check(result.bands.count == 4, "AutoEQ band count")
    check(result.bands[0].type == .bell, "AutoEQ bell type")
    close(result.bands[0].frequency, 105, 0.001, "AutoEQ frequency")
    close(result.bands[0].gain, 5.5, 0.001, "AutoEQ gain")
    close(result.bands[0].q, 0.70, 0.001, "AutoEQ Q")
    check(result.bands[1].type == .lowShelf, "AutoEQ low shelf")
    check(result.bands[2].type == .highShelf, "AutoEQ high shelf")
    check(!result.bands[2].enabled, "AutoEQ disabled filter")
    check(result.bands[3].type == .highPass, "AutoEQ high pass")

    let commaText = """
    Preamp: -4,5 dB
    Filter 1: ON PK Fc 1000,5 Hz Gain -3,0 dB Q 1,2
    """
    let commaResult = try AutoEQParser.parse(text: commaText)
    close(commaResult.preamp, -4.5, 0.001, "AutoEQ comma preamp")
    close(commaResult.bands[0].frequency, 1_000.5, 0.001, "AutoEQ comma frequency")
    close(commaResult.bands[0].gain, -3, 0.001, "AutoEQ comma gain")
    close(commaResult.bands[0].q, 1.2, 0.001, "AutoEQ comma Q")

    let many = (1...20).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1.0 dB Q 1.0" }
    let manyResult = try AutoEQParser.parse(text: many.joined(separator: "\n"))
    check(manyResult.bands.count == EQBandLimits.maxBands, "AutoEQ band clamp")
    check(!manyResult.warnings.isEmpty, "AutoEQ warning for extra filters")

    check((try? AutoEQParser.parse(text: "   \n")) == nil, "AutoEQ rejects empty text")
    check((try? AutoEQParser.parse(text: "GraphicEQ: 20 -3; 25 -2.5")) == nil, "AutoEQ rejects GraphicEQ")

    let exportSettings = EQSettings(
        bands: [
            EQBand(type: .bell, frequency: 440, gain: 3.5, q: 1.2),
            EQBand(type: .highShelf, frequency: 10_000, gain: -2, q: 0.7, enabled: false),
            EQBand(type: .lowPass, frequency: 30, gain: 0, q: 0.707)
        ],
        preamp: -5.25
    )
    let exported = AutoEQExporter.text(for: exportSettings, name: "Round Trip")
    check(exported.contains("Preamp: -5.25 dB"), "AutoEq export preamp")
    check(exported.contains("Filter 1: ON PK Fc 440.00 Hz Gain 3.50 dB Q 1.20"), "AutoEq export bell")
    check(exported.contains("Filter 2: OFF HSC Fc 10000.00 Hz Gain -2.00 dB Q 0.70"), "AutoEq export shelf")
    check(exported.contains("Filter 3: ON LP Fc 30.00 Hz Q 0.71"), "AutoEq export low-pass")

    let roundTrip = try AutoEQParser.parse(text: exported)
    close(roundTrip.preamp, -5.25, 0.001, "AutoEq export preamp round trip")
    check(roundTrip.bands.count == 3, "AutoEq export band count")
    check(roundTrip.bands[0].type == .bell, "AutoEq export bell type")
    close(roundTrip.bands[0].frequency, 440, 0.001, "AutoEq export frequency")
    close(roundTrip.bands[0].gain, 3.5, 0.001, "AutoEq export gain")
    close(roundTrip.bands[0].q, 1.2, 0.001, "AutoEq export Q")
    check(!roundTrip.bands[1].enabled, "AutoEq export disabled flag")
    check(roundTrip.bands[2].type == .lowPass, "AutoEq export low-pass type")
    check(AutoEQExporter.filterToken(for: .lowShelf) == "LSC", "AutoEq export low-shelf token")
    check(AutoEQExporter.filterToken(for: .bandPass) == "BP", "AutoEq export band-pass token")
}

// MARK: - Codable persistence

do {
    let settings = EQSettings(
        bands: [EQBand(type: .highShelf, frequency: 9_500, gain: 2.5, q: 0.8)],
        preamp: -3,
        balance: 0.2,
        limiter: false,
        bypass: true
    )
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
    check(decoded == settings, "EQSettings Codable round trip")

    let preset = Preset(name: "Test", settings: settings)
    let presetData = try JSONEncoder().encode(preset)
    let decodedPreset = try JSONDecoder().decode(Preset.self, from: presetData)
    check(decodedPreset == preset, "Preset Codable round trip")
    check(BuiltInPresets.all.count >= 5, "built-in presets exist")
}

// MARK: - Throughput

do {
    let frames = 48_000 * 10
    let processor = EQProcessor()
    processor.prepare(sampleRate: 48_000)
    processor.update(settings: EQSettings.flat, sampleRate: 48_000)
    var left = [Float](repeating: 0, count: 512)
    var right = [Float](repeating: 0, count: 512)
    let start = Date()
    var remaining = frames
    while remaining > 0 {
        let count = min(remaining, 512)
        let blockCount = count
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                processor.processPlanar(
                    left: leftBuffer.baseAddress!,
                    right: rightBuffer.baseAddress!,
                    frameCount: blockCount
                )
            }
        }
        remaining -= count
    }
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "Processed 10 s of stereo audio in %.3f s (%.0fx realtime)", elapsed, 10 / elapsed))
    check(elapsed < 2, "processor runs faster than realtime")
}

print(failures == 0 ? "PASS: \(checks) checks" : "FAILED: \(failures) of \(checks) checks")
exit(failures == 0 ? 0 : 1)
