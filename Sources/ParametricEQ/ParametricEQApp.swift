//  ParametricEQApp.swift
//  ParametricEQ
//
//  App entry point and AppKit window lifecycle.
//
//  The main window is created manually so it can be reopened from the Dock or
//  the menu-bar item. This file also hosts hidden developer flags.

import SwiftUI
import AppKit
import EQCore

/// SwiftUI entry point. The only scene is the menu-bar extra; the main
/// window is managed by ``AppDelegate`` so it can be opened from both the
/// menu bar and the Dock. The app is a regular foreground app (Dock icon),
/// not an `LSUIElement`.
@main
struct ParametricEQApp: App {
    /// AppKit lifecycle + window management.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Shared application model. It is also used by AppDelegate.
    @StateObject private var model = AppModel.shared

    /// Menu-bar scene. The label switches between the active/inactive
    /// four-bar template images.
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(nsImage: model.isRunning ? MenuBarIcon.active : MenuBarIcon.inactive)
                .accessibilityLabel("Parametric EQ")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Owns the single main window, the Dock/reopen behaviour and the hidden
/// developer command-line flags.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Weak access point used by MenuBarView to open the window.
    static weak var shared: AppDelegate?

    /// Retained window instance. Closing it hides the UI but keeps the app
    /// running in the Dock/menu bar; `isReleasedWhenClosed` is false.
    private var window: NSWindow?

    /// Sets the regular activation policy (Dock icon), creates/shows the main
    /// window, warms the TCC subsystem and schedules developer flags.
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Touching the TCC preflight before Core Audio starts avoids a HAL
        // deadlock seen on macOS 26 when the permission has never been queried.
        let permission = AudioPermission.preflight
        Diagnostics.log("launch tcc preflight=\(permission)")
        NSApp.setActivationPolicy(.regular)
        showMainWindow()
        scheduleSnapshotIfRequested()
        scheduleDiagnosticsIfRequested()
        if CommandLine.arguments.contains("--check-permission") {
            Diagnostics.log("tcc preflight=\(AudioPermission.preflight) authorized=\(AudioPermission.isAuthorized)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
    }

    /// Hidden flags used during development:
    /// `--enable-audio` starts the engine; `--quit-after N` terminates after
    /// N seconds so automated tests cannot leave audio running.
    private func scheduleDiagnosticsIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--enable-audio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                AppModel.shared.enable()
            }
        }
        if let index = arguments.firstIndex(of: "--quit-after"),
           arguments.indices.contains(index + 1),
           let seconds = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSApp.terminate(nil)
            }
        }
    }

    /// Hidden `--snapshot <path>` flag. Renders the window’s content view into
    /// a PNG via AppKit caching, then terminates. Useful for docs and for
    /// verifying layout without screen-recording permission.
    private func scheduleSnapshotIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(flagIndex + 1) else { return }
        let path = arguments[flagIndex + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let window = self?.window, let view = window.contentView else {
                NSApp.terminate(nil)
                return
            }
            let bounds = view.bounds
            guard let representation = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: bounds, to: representation)
            if let data = representation.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Closing the window must not quit the equalizer; audio keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock click/⌘-Tab reopen: bring the existing window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// Flushes settings and stops the audio engine before process exit.
    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    /// Creates the window lazily, deminiaturizes it, activates the app and
    /// brings it to the front. Safe to call repeatedly.
    func showMainWindow() {
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Builds the borderless-looking NSWindow:
    /// - full-size content under a transparent titlebar;
    /// - no background dragging (graph handles must win);
    /// - saved frame, minimum size and no tabbing.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ContentView(model: AppModel.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Parametric EQ"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = .appBackground
        window.isOpaque = true
        window.hasShadow = true
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1_090, height: 735))
        window.minSize = NSSize(width: 1_000, height: 670)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.isReleasedWhenClosed = false

        if !window.setFrameUsingName("ParametricEQMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("ParametricEQMainWindow")
        return window
    }

    /// Intentionally empty: the window is retained and can be reopened from
    /// the Dock or menu bar.
    func windowWillClose(_ notification: Notification) {
        // Keep the window instance so the menu bar can reopen it instantly.
    }
}
