//  Biquad.swift
//  ParametricEQ
//
//  RBJ biquad design, frequency response and per-channel filter state.
//
//  The math is pure and testable; the renderer owns the mutable states.

import Foundation

/// Normalised coefficients (a0 == 1) for one second-order section.
///
/// The renderer stores a fixed-size array of these values and interpolates
/// them per sample. `magnitudeDB` is only used by the UI response cache.
public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    /// Creates a coefficient set. Callers normally use ``BiquadDesign``
    /// instead of constructing values by hand.
    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// A pass-through section: `H(z) = 1`.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Guards against NaN/Inf escaping from extreme UI or imported values.
    public var isFinite: Bool {
        b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite
    }

    /// Complex magnitude of the filter at a frequency, in decibels.
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, frequency > 0 else { return 0 }
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w)
        let sin1 = sin(w)
        let cos2 = cos(2 * w)
        let sin2 = sin(2 * w)

        let numeratorReal = b0 + b1 * cos1 + b2 * cos2
        let numeratorImaginary = -(b1 * sin1 + b2 * sin2)
        let denominatorReal = 1 + a1 * cos1 + a2 * cos2
        let denominatorImaginary = -(a1 * sin1 + a2 * sin2)

        let numerator = hypot(numeratorReal, numeratorImaginary)
        let denominator = hypot(denominatorReal, denominatorImaginary)
        guard denominator > 0 else { return 0 }
        return 20 * log10(max(numerator / denominator, 1e-12))
    }
}

/// RBJ cookbook biquad designer. Every EQ shape is translated into one
/// normalised second-order section here.
public enum BiquadDesign {
    /// Designs one RBJ cookbook biquad. `q` is used both as the classical
    /// quality factor for bells/passes and as the shelf slope control.
    public static func coefficients(
        type: EQFilterType,
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        guard sampleRate > 1_000 else { return .identity }

        let nyquistLimit = sampleRate * 0.49
        let f = frequency.clamped(to: 10...max(11, nyquistLimit))
        let q = q.clamped(to: 0.05...20)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)
        let alpha = sinW / (2 * q)

        var b0 = 1.0
        var b1 = 0.0
        var b2 = 0.0
        var a0 = 1.0
        var a1 = 0.0
        var a2 = 0.0

        switch type {
        case .bell:
            let a = pow(10, gainDB / 40)
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a

        case .lowShelf:
            let a = pow(10, gainDB / 40)
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1) - (a - 1) * cosW + 2 * sqrtA * alpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - 2 * sqrtA * alpha)
            a0 = (a + 1) + (a - 1) * cosW + 2 * sqrtA * alpha
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - 2 * sqrtA * alpha

        case .highShelf:
            let a = pow(10, gainDB / 40)
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1) + (a - 1) * cosW + 2 * sqrtA * alpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - 2 * sqrtA * alpha)
            a0 = (a + 1) - (a - 1) * cosW + 2 * sqrtA * alpha
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - 2 * sqrtA * alpha

        case .lowPass:
            b0 = (1 - cosW) / 2
            b1 = 1 - cosW
            b2 = (1 - cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha

        case .highPass:
            b0 = (1 + cosW) / 2
            b1 = -(1 + cosW)
            b2 = (1 + cosW) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha

        case .notch:
            b0 = 1
            b1 = -2 * cosW
            b2 = 1
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha

        case .bandPass:
            b0 = alpha
            b1 = 0
            b2 = -alpha
            a0 = 1 + alpha
            a1 = -2 * cosW
            a2 = 1 - alpha
        }

        guard a0.isFinite, abs(a0) > .ulpOfOne else { return .identity }
        let result = BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
        return result.isFinite ? result : .identity
    }
}

/// Transposed direct form II state for one channel of one biquad.
///
/// The renderer keeps `maxBands * 2` of these (one per channel per band).
/// Reset them whenever the engine starts or the sample rate changes.
public struct BiquadState {
    public var z1: Double = 0
    public var z2: Double = 0

    /// Creates a zeroed filter memory.
    public init() {}

    /// Clears the two delay elements. Called when audio restarts.
    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Processes one sample with the supplied coefficients and updates the
    /// filter memory. `@inline(__always)` keeps the per-sample loop tight.
    @inline(__always)
    public mutating func process(_ input: Double, _ coefficients: BiquadCoefficients) -> Double {
        let output = coefficients.b0 * input + z1
        z1 = coefficients.b1 * input - coefficients.a1 * output + z2
        z2 = coefficients.b2 * input - coefficients.a2 * output
        return output
    }
}
