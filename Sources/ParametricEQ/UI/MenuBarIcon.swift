//  MenuBarIcon.swift
//  ParametricEQ
//
//  Template four-bar icon used by the menu-bar item.

import AppKit

/// The four-bar mark used in the header, Dock icon and menu bar.
enum MenuBarIcon {
    /// Opaque four bars while the engine is running.
    static let active = makeImage(active: true)
    /// Dimmed bars plus a dot while the engine is off.
    static let inactive = makeImage(active: false)

    /// Draws an 18×18 template image at native point size.
    private static func makeImage(active: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let heights: [CGFloat] = [5.5, 10.5, 7.5, 13.5]
            let width: CGFloat = 2.3
            let gap: CGFloat = 1.5
            let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
            let startX = (rect.width - total) / 2
            let baseline: CGFloat = 2.2

            let alpha: CGFloat = active ? 1.0 : 0.34
            NSColor.black.withAlphaComponent(alpha).setFill()
            for (index, height) in heights.enumerated() {
                let x = startX + CGFloat(index) * (width + gap)
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: baseline, width: width, height: height),
                    xRadius: width / 2,
                    yRadius: width / 2
                )
                bar.fill()
            }

            if !active {
                // A small dot below makes the "off" state legible without a
                // second icon language.
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 1, y: 0.2, width: 2, height: 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
