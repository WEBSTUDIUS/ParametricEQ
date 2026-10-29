//  SpectrumCapture.swift
//  ParametricEQ
//
//  Mono ring buffer between the audio callback and the spectrum analyzer.
//
//  The producer uses trylock and skips a block rather than stalling audio.

import Foundation
import os.lock

/// A tiny lock-free-on-the-read-side ring buffer that carries mono samples
/// from the audio render thread to the spectrum analyzer.
public final class SpectrumCapture: @unchecked Sendable {
    /// Number of mono samples retained (about 340 ms at 48 kHz).
    public static let capacity = 16_384

    /// Serialises the producer (audio) and consumer (FFT) sides.
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    /// Fixed storage; no allocation ever happens on the audio thread.
    private let samples: UnsafeMutablePointer<Float>
    /// Written only while holding ``lock``; wraps modulo ``capacity``.
    private var writeIndex = 0

    /// Allocates the lock and the fixed ring buffer.
    public init() {
        lock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        samples = .allocate(capacity: Self.capacity)
        samples.initialize(repeating: 0, count: Self.capacity)
    }

    /// Releases the ring buffer and lock.
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        samples.deallocate()
    }

    /// Called from the audio thread. If the UI happens to be reading, this
    /// block is skipped rather than blocking the render thread.
    public func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        guard count > 0, os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }

        var index = writeIndex
        for frame in 0..<count {
            samples[index] = (left[frame] + right[frame]) * 0.5
            index += 1
            if index >= Self.capacity { index = 0 }
        }
        writeIndex = index
    }

    /// Copies the newest `count` samples in chronological order. Returns false
    /// if the buffer does not have enough history yet.
    @discardableResult
    public func readLatest(into destination: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        guard count > 0, count <= Self.capacity else { return false }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        var index = writeIndex - count
        while index < 0 { index += Self.capacity }
        for offset in 0..<count {
            destination[offset] = samples[index]
            index += 1
            if index >= Self.capacity { index = 0 }
        }
        return true
    }

    /// Clears the ring so a restarted engine cannot display stale audio.
    public func reset() {
        os_unfair_lock_lock(lock)
        samples.update(repeating: 0, count: Self.capacity)
        writeIndex = 0
        os_unfair_lock_unlock(lock)
    }
}
