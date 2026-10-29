//  SpectrumAnalyzer.swift
//  ParametricEQ
//
//  Timer-driven vDSP FFT analyzer.
//
//  Consumes the lock-protected sample ring and publishes 72 log-frequency
//  bins plus a peak level to the graph.

import Foundation
import Accelerate
import EQCore

/// Pulls recent audio from the render thread and turns it into a smoothed
/// log-frequency spectrum for the graph.
final class SpectrumAnalyzer: @unchecked Sendable {
    /// Number of log-spaced display bins between 20 Hz and 20 kHz.
    static let binCount = 72

    /// Delivered on the main thread with (normalised bins, peak level).
    var onUpdate: (([Float], Float) -> Void)?

    /// 4096-point FFT (~85 ms at 48 kHz); small enough for 30 fps.
    private let fftSize = 4_096
    /// log2(fftSize), required by vDSP.
    private let log2n = vDSP_Length(12)
    /// Serial background queue that performs the FFT off the main thread.
    private let queue = DispatchQueue(label: "com.andreyilin.ParametricEQ.spectrum", qos: .userInitiated)
    /// Reusable vDSP FFT setup.
    private var fftSetup: FFTSetup?
    /// Weak reference to the engine’s ring buffer; avoids retaining the engine.
    private weak var capture: SpectrumCapture?
    /// 30 fps main-run-loop timer.
    private var timer: Timer?
    /// Coalesces ticks while a previous FFT is still running.
    private var isComputing = false
    /// Attack/release-smoothed display values.
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.binCount)
    /// Current aggregate sample rate, used for bin mapping.
    private var sampleRate: Double = 48_000

    /// Hann window applied before the FFT.
    private var window = [Float](repeating: 0, count: 4_096)
    /// Latest 4096 mono samples copied from the ring buffer.
    private var timeDomain = [Float](repeating: 0, count: 4_096)
    /// Windowed samples.
    private var windowed = [Float](repeating: 0, count: 4_096)
    /// Split-complex real part.
    private var real = [Float](repeating: 0, count: 2_048)
    /// Split-complex imaginary part.
    private var imaginary = [Float](repeating: 0, count: 2_048)
    /// Squared FFT magnitudes (vDSP_zvmags output).
    private var magnitudes = [Float](repeating: 0, count: 2_048)

    /// Creates the FFT setup and the Hann window once.
    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    /// Stops the timer and releases the FFT setup.
    deinit {
        timer?.invalidate()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    /// Starts the 30 fps timer and binds the ring buffer. Idempotent.
    func start(capture: SpectrumCapture) {
        self.capture = capture
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.008
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the timer and clears smoothing history.
    func stop() {
        timer?.invalidate()
        timer = nil
        capture = nil
        smoothed = Array(repeating: 0, count: Self.binCount)
    }

    /// Schedules one FFT. Runs at most one computation at a time so a slow
    /// frame cannot build a queue of stale work.
    private func tick() {
        guard !isComputing, let capture else { return }
        isComputing = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.compute(capture: capture)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.smoothed = result.spectrum
                self.onUpdate?(result.spectrum, result.level)
                self.isComputing = false
            }
        }
    }

    /// Reads 4096 samples, applies the Hann window, runs a real FFT, maps
    /// squared magnitudes to 72 log bins and applies attack/release smoothing.
    /// This is the only heavy spectrum function and runs off main.
    private func compute(capture: SpectrumCapture) -> (spectrum: [Float], level: Float) {
        guard let fftSetup else {
            return (Array(repeating: 0, count: Self.binCount), 0)
        }

        let read = timeDomain.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return capture.readLatest(into: base, count: fftSize)
        }
        guard read else {
            return (smoothed, 0)
        }

        var level: Float = 0
        vDSP_maxmgv(timeDomain, 1, &level, vDSP_Length(fftSize))

        // Hann window reduces spectral leakage; vDSP_HANN_NORM is a
        // coherent-gain-normalised window.
        vDSP_vmul(timeDomain, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                guard let realBase = realBuffer.baseAddress,
                      let imaginaryBase = imaginaryBuffer.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                windowed.withUnsafeBufferPointer { windowBuffer in
                    guard let windowBase = windowBuffer.baseAddress else { return }
                    windowBase.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }

                // Packed real-to-complex FFT: the result is stored in
                // split.realp/imagp with vDSP’s factor-of-two convention.
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                magnitudes.withUnsafeMutableBufferPointer { magnitudeBuffer in
                    guard let magnitudeBase = magnitudeBuffer.baseAddress else { return }
                    vDSP_zvmags(&split, 1, magnitudeBase, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        let sampleRate = captureSampleRate()
        let nyquist = sampleRate / 2
        let half = fftSize / 2
        // vDSP_zvmags returns squared magnitudes, so the dB conversion uses
        // 10*log10 and a reference of fftSize/2. This maps a full-scale
        // sine to roughly 0 dBFS before the display floor is applied.
        let scale = 20 * log10(Float(fftSize) / 2)
        var next = [Float](repeating: 0, count: Self.binCount)

        // Map FFT bins onto 72 logarithmically spaced display bands. Taking
        // the peak inside each band gives a stable, readable curve.
        for bin in 0..<Self.binCount {
            let lowFrequency = 20.0 * pow(1_000.0, Double(bin) / Double(Self.binCount))
            let highFrequency = 20.0 * pow(1_000.0, Double(bin + 1) / Double(Self.binCount))
            let lowIndex = max(1, min(half - 1, Int(lowFrequency / nyquist * Double(half))))
            let highIndex = max(lowIndex, min(half - 1, Int(highFrequency / nyquist * Double(half))))

            var peak: Float = 0
            for index in lowIndex...highIndex {
                peak = max(peak, magnitudes[index])
            }
            let db = 10 * log10(max(peak, 1e-10)) - scale
            let normalized = ((db + 72) / 72).clamped(to: 0...1)
            // Fast attack, slow release: transients appear immediately and
            // decay gracefully instead of flickering.
            let previous = smoothed[bin]
            let coefficient: Float = normalized > previous ? 0.62 : 0.14
            next[bin] = previous + (normalized - previous) * coefficient
        }

        return (next, min(1, level * 1.5))
    }

    /// Snapshot of the current sample rate for the bin mapping.
    private func captureSampleRate() -> Double {
        sampleRate
    }

    /// Called when the aggregate format changes.
    func setSampleRate(_ value: Double) {
        guard value > 1_000 else { return }
        sampleRate = value
    }
}
