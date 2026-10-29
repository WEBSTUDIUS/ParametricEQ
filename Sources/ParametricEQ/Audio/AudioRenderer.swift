//  AudioRenderer.swift
//  ParametricEQ
//
//  Audio-device callback: ABL conversion, DSP call, spectrum feed and output.
//
//  Real-time safe: all buffers are preallocated and no locks are taken here
//  (only the EQ processor’s trylock path is used).

import Foundation
import CoreAudio
import Darwin
import EQCore

/// Converts the aggregate device's buffer lists to planar stereo, runs the EQ
/// and writes the result back out. All buffers are allocated up front.
final class AudioRenderer: @unchecked Sendable {
    /// The real-time EQ engine shared with the UI model.
    private let processor: EQProcessor
    /// Ring buffer feeding the spectrum analyser.
    private let capture: SpectrumCapture
    /// Preallocated scratch capacity; one render block is normally 128–1024 frames.
    private let maxFrames = 16_384
    /// Planar scratch buffers. They avoid per-callback allocations and let the
    /// renderer handle interleaved or non-interleaved ABLs uniformly.
    private let left: UnsafeMutablePointer<Float>
    /// Right-channel planar scratch buffer.
    private let right: UnsafeMutablePointer<Float>
    /// Format of the tap input; retained for diagnostics/validation.
    private let inputFormat: AudioStreamBasicDescription
    /// Format of the aggregate output; used to convert byte sizes to frames.
    private let outputFormat: AudioStreamBasicDescription
    /// One-shot diagnostic flag, never read by the audio path itself.
    private var hasRenderedOnce = false
    /// Diagnostic callback counter.
    private var renderCount = 0

    /// Allocates the two planar scratch buffers. Called once when the
    /// engine starts, never from the render callback.
    init(
        processor: EQProcessor,
        capture: SpectrumCapture,
        inputFormat: AudioStreamBasicDescription,
        outputFormat: AudioStreamBasicDescription
    ) {
        self.processor = processor
        self.capture = capture
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        left = .allocate(capacity: maxFrames)
        right = .allocate(capacity: maxFrames)
        left.initialize(repeating: 0, count: maxFrames)
        right.initialize(repeating: 0, count: maxFrames)
    }

    /// Releases the scratch buffers.
    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Single audio callback. Steps:
    /// 1. zero the hardware-owned output buffers;
    /// 2. derive the frame count from the output ABL;
    /// 3. copy the tap into planar L/R;
    /// 4. run the EQ;
    /// 5. feed the spectrum ring buffer;
    /// 6. write L/R back and silence any extra channels.
    /// The function performs no allocation and must stay real-time safe.
    func render(
        inputData: UnsafePointer<AudioBufferList>?,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let outputData else { return }
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard outputBuffers.count > 0 else { return }

        // The hardware owns the output buffer size. Clearing it first means
        // any frames we cannot fill are emitted as silence rather than garbage.
        for index in 0..<outputBuffers.count {
            if let data = outputBuffers[index].mData {
                memset(data, 0, Int(outputBuffers[index].mDataByteSize))
            }
        }

        let outputFrames = frameCount(for: outputBuffers, format: outputFormat)
        guard outputFrames > 0 else { return }
        let frames = min(outputFrames, maxFrames, 16_384)
        if !hasRenderedOnce {
            hasRenderedOnce = true
            let inputBuffers = inputData.map { UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: $0)) }
            Diagnostics.log("first render frames=\(frames) outputBuffers=\(outputBuffers.count) inputBuffers=\(inputBuffers?.count ?? -1) outCh=\(outputBuffers.first?.mNumberChannels ?? 0) inCh=\(inputBuffers?.first?.mNumberChannels ?? 0)")
        }

        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)

        if let inputData {
            let inputBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            readInput(inputBuffers, frames: frames)
        }

        var inputPeak: Float = 0
        for frame in 0..<frames {
            inputPeak = max(inputPeak, abs(left[frame]), abs(right[frame]))
        }

        processor.processPlanar(left: left, right: right, frameCount: frames)

        var outputPeak: Float = 0
        for frame in 0..<frames {
            outputPeak = max(outputPeak, abs(left[frame]), abs(right[frame]))
        }

        capture.append(left: left, right: right, count: frames)
        writeOutput(outputBuffers, frames: frames)

        if Diagnostics.isEnabled && (renderCount < 3 || renderCount % 200 == 0) {
            Diagnostics.log("render #\(renderCount) inPeak=\(inputPeak) outPeak=\(outputPeak) frames=\(frames)")
        }
        renderCount += 1
    }

    /// Infers the callback length from `mDataByteSize`. A single buffer is
    /// interleaved; two or more buffers are one channel per buffer.
    private func frameCount(
        for buffers: UnsafeMutableAudioBufferListPointer,
        format: AudioStreamBasicDescription
    ) -> Int {
        let first = buffers[0]
        let channels = max(1, Int(first.mNumberChannels))
        if buffers.count >= 2 {
            return Int(first.mDataByteSize) / MemoryLayout<Float>.size
        }
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    }

    /// Copies the tap buffer list into the planar scratch buffers. Handles
    /// stereo non-interleaved, stereo interleaved and mono (duplicated).
    private func readInput(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard buffers.count > 0 else { return }

        if buffers.count >= 2 {
            copyChannel(buffers[0], to: left, frames: frames)
            copyChannel(buffers[1], to: right, frames: frames)
            return
        }

        let buffer = buffers[0]
        let channels = max(1, Int(buffer.mNumberChannels))
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let availableFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        guard availableFrames > 0 else { return }

        if channels == 1 {
            for frame in 0..<availableFrames {
                let value = data[frame]
                left[frame] = value
                right[frame] = value
            }
        } else {
            for frame in 0..<availableFrames {
                let base = frame * channels
                left[frame] = data[base]
                right[frame] = data[base + 1]
            }
        }
    }

    /// Copies one non-interleaved input buffer into a planar destination.
    /// Copies one planar source channel into a non-interleaved output buffer.
    private func copyChannel(
        _ buffer: AudioBuffer,
        to destination: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard let data = buffer.mData else { return }
        let availableFrames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        guard availableFrames > 0 else { return }
        memcpy(destination, data, availableFrames * MemoryLayout<Float>.size)
    }

    /// Writes processed stereo into the output ABL. For interleaved devices
    /// only the first two channels are written; additional channels stay
    /// silent (the stereo limitation is documented in the README).
    private func writeOutput(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard buffers.count > 0 else { return }

        if buffers.count >= 2 {
            copyChannel(left, to: buffers[0], frames: frames)
            copyChannel(right, to: buffers[1], frames: frames)
            return
        }

        let buffer = buffers[0]
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let availableFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        guard availableFrames > 0 else { return }

        if channels == 1 {
            for frame in 0..<availableFrames {
                data[frame] = (left[frame] + right[frame]) * 0.5
            }
        } else {
            for frame in 0..<availableFrames {
                let base = frame * channels
                data[base] = left[frame]
                data[base + 1] = right[frame]
                if channels > 2 {
                    for channel in 2..<channels {
                        data[base + channel] = 0
                    }
                }
            }
        }
    }

    /// Copies one planar source channel into a non-interleaved output buffer.
    private func copyChannel(
        _ source: UnsafeMutablePointer<Float>,
        to buffer: AudioBuffer,
        frames: Int
    ) {
        guard let data = buffer.mData else { return }
        let availableFrames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        guard availableFrames > 0 else { return }
        memcpy(data, source, availableFrames * MemoryLayout<Float>.size)
    }
}
