//  AudioPermission.swift
//  ParametricEQ
//
//  Private TCC SPI bridge for the System Audio Recording permission.
//
//  Used for diagnostics and for opening the correct Settings pane; Core Audio
//  remains the source of truth for whether the tap can start.

import Foundation
import AppKit

/// Small wrapper around the private TCC SPI used by Apple's own system-audio
/// samples. Core Audio has no public preflight/request API for the
/// "System Audio Recording" permission.
enum AudioPermission {
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    /// dlopen handle to the private TCC framework. `nil` on systems where
    /// the framework cannot be loaded.
    private static let tccHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    /// 0 = authorized, 1 = denied, 2 = not determined, -1 = unavailable.
    static var preflight: Int {
        guard let tccHandle,
              let symbol = dlsym(tccHandle, "TCCAccessPreflight") else { return -1 }
        let function = unsafeBitCast(symbol, to: PreflightFunction.self)
        return function("kTCCServiceAudioCapture" as CFString, nil)
    }

    /// Convenience check for the authorised TCC state.
    static var isAuthorized: Bool { preflight == 0 }

    /// Requests the private `kTCCServiceAudioCapture` permission. The
    /// completion is delivered by TCC; callers must dispatch UI work to main.
    static func request(completion: @escaping (Bool) -> Void) {
        guard let tccHandle,
              let symbol = dlsym(tccHandle, "TCCAccessRequest") else {
            completion(false)
            return
        }
        let function = unsafeBitCast(symbol, to: RequestFunction.self)
        function("kTCCServiceAudioCapture" as CFString, nil, completion)
    }

    /// Opens the Screen & System Audio Recording pane, with a fallback URL
    /// for older macOS versions.
    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
