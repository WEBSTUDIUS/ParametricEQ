//  AudioObjectUtils.swift
//  ParametricEQ
//
//  Thin, synchronous Core Audio property helpers.
//
//  All calls are made from the control queue (never the render thread).

import Foundation
import CoreAudio

/// Errors thrown by the low-level Core Audio property helpers.
enum AudioObjectError: LocalizedError {
    case propertyFailed(selector: AudioObjectPropertySelector, status: OSStatus)

    /// Formats the failing four-character selector and OSStatus.
    var errorDescription: String? {
        switch self {
        case let .propertyFailed(selector, status):
            return "Core Audio property \(fourCC(selector)) failed with status \(status)."
        }
    }
}

/// Converts a Core Audio four-character code into a printable string
/// for logs and error messages.
func fourCC(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
    return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, encoding: .ascii) ?? "????"
}

/// Convenience constants shared by the Core Audio helpers.
extension AudioObjectID {
    /// The singleton Core Audio system object.
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// The sentinel returned when an AudioObjectID is invalid.
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    /// True when the object id is not `kAudioObjectUnknown`.
    var isValid: Bool { self != .unknown }
}

/// Shorthand initialiser that defaults to global scope and the main element.
extension AudioObjectPropertyAddress {
    /// Creates an address for a selector with optional scope/element.
    init(_ selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// Synchronous wrappers around `AudioObjectGetPropertyData`.
/// All functions are safe to call from the control queue, never from the
/// real-time render thread.
enum AudioObjectReader {
    /// Returns the current default output device (`kAudioHardwarePropertyDefaultOutputDevice`).
    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID.unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID.system,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID.unknown else { return nil }
        return deviceID
    }

    /// Reads the persistent UID string used to build the aggregate device.
    static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyDeviceUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    /// Reads the human-readable device name for the footer.
    static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(kAudioObjectPropertyName)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    /// Reads the device’s nominal sample rate.
    static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, value > 0 else { return nil }
        return value
    }

    /// Reads the stream format for the input or output scope of a device.
    static func streamFormat(
        _ objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamFormat, scope: scope)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, value.mSampleRate > 0 else { return nil }
        return value
    }

    /// Reads the format of the process tap itself (`kAudioTapPropertyFormat`).
    static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(kAudioTapPropertyFormat)
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &value)
        guard status == noErr, value.mSampleRate > 0 else { return nil }
        return value
    }

    /// Translates a PID into a Core Audio process object so the global tap
    /// can exclude this app and avoid a feedback loop.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var processID = pid
        var value = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID.system,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &processID,
            &size,
            &value
        )
        guard status == noErr, value.isValid else { return nil }
        return value
    }
}

/// Validation helpers for the formats accepted by the renderer.
extension AudioStreamBasicDescription {
    /// The renderer only supports native 32-bit float PCM.
    var isFloat32PCM: Bool {
        mFormatID == kAudioFormatLinearPCM
            && (mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && mBitsPerChannel == 32
            && mChannelsPerFrame > 0
    }

    /// True for one-buffer-per-channel layouts.
    var isNonInterleaved: Bool {
        (mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }

    /// Convenience bridge from the C field to Swift Int.
    var channelCount: Int { Int(mChannelsPerFrame) }
}
