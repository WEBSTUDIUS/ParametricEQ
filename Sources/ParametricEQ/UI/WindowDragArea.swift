//  WindowDragArea.swift
//  ParametricEQ
//
//  AppKit bridge that starts a native window drag from the header strip.

import SwiftUI
import AppKit

/// A transparent AppKit view that starts a native window drag on mouse down.
/// Used in the header so the rest of the window can disable
/// `isMovableByWindowBackground` and let graph handles/sliders receive drags.
struct WindowDragArea: NSViewRepresentable {
    /// Creates the transparent drag view.
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    /// No updates required.
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// A view that forwards mouse-down to `NSWindow.performDrag(with:)`.
    private final class DragView: NSView {
        override var acceptsFirstResponder: Bool { false }

        /// Starts a native window drag using the current event.
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
