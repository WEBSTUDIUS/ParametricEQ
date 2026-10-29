//  EQProcessor.swift
//  ParametricEQ
//
//  Real-time parametric EQ renderer.
//
//  Owns all DSP buffers and states. The audio thread never allocates, never
//  waits on a lock and never touches Swift collections. UI updates are
//  published into a lock-protected block and interpolated per sample.

import Foundation
import os.lock

/// A real-time safe parametric EQ renderer.
///
/// The audio thread never allocates, never waits on a lock and never touches
/// Swift collections. UI updates are published into a small lock-protected
/// coefficient block; the render thread picks them up with `trylock` and
/// smoothly interpolates towards them.
public final class EQProcessor: @unchecked Sendable {
    private let maxBands = EQBandLimits.maxBands
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    /// Coefficient blocks are triple-buffered:
    /// - `sharedCoefficients` is written by the UI under `lock`;
    /// - `targetCoefficients` is the audio thread’s snapshot;
    /// - `currentCoefficients` is smoothly interpolated per sample.
    private let sharedCoefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let targetCoefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let currentCoefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let states: UnsafeMutablePointer<BiquadState>

    /// Fixed look-ahead delay lines used by the limiter. They always run,
    /// so enabling/disabling the limiter never changes latency.
    private let delayCapacity = 256
    private let delayLeft: UnsafeMutablePointer<Double>
    private let delayRight: UnsafeMutablePointer<Double>

    private var sampleRate: Double = 48_000
    private var sharedPreamp: Double = 1
    private var sharedBalance: Double = 0
    private var sharedLimiter = true
    private var sharedBypass = false

    private var targetPreamp: Double = 1
    private var targetBalance: Double = 0
    private var targetLimiter = true
    private var targetBypass = false

    private var currentPreamp: Double = 1
    private var currentBalance: Double = 0
    private var currentWet: Double = 0

    private var coefficientSmoothing: Double = 0.002
    private var gainSmoothing: Double = 0.002

    private var delaySamples = 64
    private var delayWriteIndex = 0
    private var limiterGain: Double = 1
    private var limiterEnvelope: Double = 0
    private var limiterRelease: Double = 0.999
    private var limiterRecovery: Double = 0.001

    /// False until the first settings snapshot has been pulled.
    private var hasTargets = false
    private var needsInitialSnap = true

    /// Allocates every buffer once. No allocation happens on the audio thread.
    public init() {
        lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        sharedCoefficients = .allocate(capacity: maxBands)
        targetCoefficients = .allocate(capacity: maxBands)
        currentCoefficients = .allocate(capacity: maxBands)
        states = .allocate(capacity: maxBands * 2)
        delayLeft = .allocate(capacity: delayCapacity)
        delayRight = .allocate(capacity: delayCapacity)

        for index in 0..<maxBands {
            sharedCoefficients.advanced(by: index).initialize(to: .identity)
            targetCoefficients.advanced(by: index).initialize(to: .identity)
            currentCoefficients.advanced(by: index).initialize(to: .identity)
        }
        for index in 0..<(maxBands * 2) {
            states.advanced(by: index).initialize(to: BiquadState())
        }
        delayLeft.initialize(repeating: 0, count: delayCapacity)
        delayRight.initialize(repeating: 0, count: delayCapacity)
    }

    /// Releases the raw buffers owned by the processor.
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        sharedCoefficients.deallocate()
        targetCoefficients.deallocate()
        currentCoefficients.deallocate()
        states.deallocate()
        delayLeft.deallocate()
        delayRight.deallocate()
    }

    /// Number of samples of latency introduced by the look-ahead limiter.
    public var latencyFrames: Int { delaySamples }

    /// Prepares the renderer for a new sample rate. Call only while audio is
    /// stopped. Coefficients are recalculated from the last published settings.
    public func prepare(sampleRate: Double) {
        guard sampleRate > 1_000 else { return }
        os_unfair_lock_lock(lock)
        self.sampleRate = sampleRate
        os_unfair_lock_unlock(lock)

        coefficientSmoothing = 1 - exp(-1 / (0.010 * sampleRate))
        gainSmoothing = 1 - exp(-1 / (0.008 * sampleRate))
        limiterRelease = exp(-1 / (0.090 * sampleRate))
        limiterRecovery = 1 - exp(-1 / (0.160 * sampleRate))
        delaySamples = min(delayCapacity - 2, max(8, Int(sampleRate * 0.0015)))

        for index in 0..<(maxBands * 2) {
            states[index].reset()
        }
        for index in 0..<maxBands {
            currentCoefficients[index] = .identity
            targetCoefficients[index] = .identity
        }
        delayLeft.update(repeating: 0, count: delayCapacity)
        delayRight.update(repeating: 0, count: delayCapacity)
        delayWriteIndex = 0
        limiterGain = 1
        limiterEnvelope = 0
        currentPreamp = 1
        currentBalance = 0
        currentWet = 0
        targetPreamp = 1
        targetBalance = 0
        hasTargets = false
        needsInitialSnap = true
    }

    /// Publishes new settings from the UI thread.
    public func update(settings: EQSettings, sampleRate: Double? = nil) {
        let sanitized = settings.sanitized()

        os_unfair_lock_lock(lock)
        if let sampleRate, sampleRate > 1_000 {
            self.sampleRate = sampleRate
        }
        let rate = self.sampleRate

        for index in 0..<maxBands {
            if index < sanitized.bands.count {
                let band = sanitized.bands[index]
                if band.enabled {
                    sharedCoefficients[index] = BiquadDesign.coefficients(
                        type: band.type,
                        frequency: band.frequency,
                        gainDB: band.gain,
                        q: band.q,
                        sampleRate: rate
                    )
                } else {
                    sharedCoefficients[index] = .identity
                }
            } else {
                sharedCoefficients[index] = .identity
            }
        }

        sharedPreamp = pow(10, sanitized.preamp / 20)
        sharedBalance = sanitized.balance
        sharedLimiter = sanitized.limiter
        sharedBypass = sanitized.bypass
        os_unfair_lock_unlock(lock)
    }

    /// Resets filter memory without changing the published settings. Call only
    /// while audio is stopped.
    public func reset() {
        for index in 0..<(maxBands * 2) {
            states[index].reset()
        }
        delayLeft.update(repeating: 0, count: delayCapacity)
        delayRight.update(repeating: 0, count: delayCapacity)
        delayWriteIndex = 0
        limiterGain = 1
        limiterEnvelope = 0
        currentWet = 0
        hasTargets = false
        needsInitialSnap = true
    }

    /// Best-effort snapshot of UI-published parameters. Uses `trylock`, so a
    /// busy UI can never stall audio; the previous targets are reused instead.
    /// The first successful pull snaps the smoothed state to the target and
    /// starts a short wet-path fade-in.
    private func pullTargetsIfNeeded() {
        guard os_unfair_lock_trylock(lock) else { return }
        for index in 0..<maxBands {
            targetCoefficients[index] = sharedCoefficients[index]
        }
        targetPreamp = sharedPreamp
        targetBalance = sharedBalance
        targetLimiter = sharedLimiter
        targetBypass = sharedBypass
        os_unfair_lock_unlock(lock)
        hasTargets = true

        if needsInitialSnap {
            needsInitialSnap = false
            currentPreamp = targetPreamp
            currentBalance = targetBalance
            currentWet = 0
            for index in 0..<maxBands {
                currentCoefficients[index] = targetCoefficients[index]
            }
            limiterGain = 1
            limiterEnvelope = 0
        }
    }

    /// Processes stereo planar audio in place. This function is real-time safe
    /// and must only be called from the audio render thread.
    public func processPlanar(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        pullTargetsIfNeeded()

        // Bypass is implemented as a wet/dry crossfade rather than by
        // stopping the filters: the tap keeps running and A/B switching is
        // click-free.
        let targetWet: Double = targetBypass ? 0 : 1
        let coefficientStep = coefficientSmoothing
        let gainStep = gainSmoothing
        let ceiling = 0.949

        for frame in 0..<frameCount {
            // One-pole gain smoothing avoids zipper noise from sliders.

            currentPreamp += (targetPreamp - currentPreamp) * gainStep
            currentWet += (targetWet - currentWet) * gainStep
            currentBalance += (targetBalance - currentBalance) * gainStep

            // Simple balance law: attenuate the opposite channel, leave the
            // selected side at unity. This is predictable with headphones.
            let balanceLeft = currentBalance > 0 ? 1 - currentBalance : 1
            let balanceRight = currentBalance < 0 ? 1 + currentBalance : 1
            let dryLeft = Double(left[frame]) * balanceLeft
            let dryRight = Double(right[frame]) * balanceRight

            var wetLeft = dryLeft * currentPreamp
            var wetRight = dryRight * currentPreamp

            // Coefficients are interpolated per sample. The cost is small
            // (16 sections) and it avoids abrupt filter changes while a band
            // is being dragged.
            for band in 0..<maxBands {
                let target = targetCoefficients[band]
                var current = currentCoefficients[band]
                current.b0 += (target.b0 - current.b0) * coefficientStep
                current.b1 += (target.b1 - current.b1) * coefficientStep
                current.b2 += (target.b2 - current.b2) * coefficientStep
                current.a1 += (target.a1 - current.a1) * coefficientStep
                current.a2 += (target.a2 - current.a2) * coefficientStep
                currentCoefficients[band] = current

                wetLeft = states[band * 2].process(wetLeft, current)
                wetRight = states[band * 2 + 1].process(wetRight, current)
            }

            var mixedLeft = dryLeft + (wetLeft - dryLeft) * currentWet
            var mixedRight = dryRight + (wetRight - dryRight) * currentWet

            // Look-ahead limiter. The delay line always runs so enabling the
            // limiter never changes latency or causes a discontinuity. The
            // envelope follows the *incoming* peak, while the delayed sample
            // is attenuated, giving ~1.5 ms of look-ahead at 48 kHz.
            var readIndex = delayWriteIndex - delaySamples
            if readIndex < 0 { readIndex += delayCapacity }
            let delayedLeft = delayLeft[readIndex]
            let delayedRight = delayRight[readIndex]
            delayLeft[delayWriteIndex] = mixedLeft
            delayRight[delayWriteIndex] = mixedRight
            delayWriteIndex += 1
            if delayWriteIndex >= delayCapacity { delayWriteIndex = 0 }

            let peak = max(abs(mixedLeft), abs(mixedRight))
            limiterEnvelope = max(peak, limiterEnvelope * limiterRelease)

            if targetLimiter {
                let desiredGain = limiterEnvelope > ceiling ? ceiling / limiterEnvelope : 1
                if desiredGain < limiterGain {
                    limiterGain = desiredGain
                } else {
                    limiterGain += (desiredGain - limiterGain) * limiterRecovery
                }
            } else {
                limiterGain += (1 - limiterGain) * limiterRecovery
            }

            mixedLeft = delayedLeft * limiterGain
            mixedRight = delayedRight * limiterGain

            // Final safety clamp: the limiter should already keep us below
            // this, but the clamp guarantees the hardware never sees > 0 dBFS.
            mixedLeft = min(max(mixedLeft, -1), 1)
            mixedRight = min(max(mixedRight, -1), 1)

            left[frame] = Float(mixedLeft)
            right[frame] = Float(mixedRight)
        }
    }
}
