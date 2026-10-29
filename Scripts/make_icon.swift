//  make_icon.swift
//  ParametricEQ
//
//  Renders the 1024×1024 four-bar app icon with AppKit. Run through swiftc,
//  then convert the PNG to .icns with sips/iconutil (see Resources/).
//

import AppKit
import Foundation

let size = 1024.0
let canvas = NSRect(x: 0, y: 0, width: size, height: size)
let image = NSImage(size: canvas.size)
image.lockFocus()
guard let context = NSGraphicsContext.current else { fatalError("No graphics context") }
context.imageInterpolation = .high
context.shouldAntialias = true

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let mint = color(0x6EE7C7)
let cyan = color(0x67E8F9)
let iconRect = NSRect(x: 52, y: 52, width: 920, height: 920)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)

NSGraphicsContext.saveGraphicsState()
iconPath.addClip()

let background = NSGradient(
    starting: color(0x131C22),
    ending: color(0x060809)
)!
background.draw(in: iconPath, angle: -70)

let topGlow = NSGradient(
    starting: mint.withAlphaComponent(0.22),
    ending: mint.withAlphaComponent(0.0)
)!
topGlow.draw(
    fromCenter: NSPoint(x: 760, y: 820),
    radius: 0,
    toCenter: NSPoint(x: 700, y: 760),
    radius: 620,
    options: []
)

let bottomGlow = NSGradient(
    starting: cyan.withAlphaComponent(0.14),
    ending: cyan.withAlphaComponent(0.0)
)!
bottomGlow.draw(
    fromCenter: NSPoint(x: 270, y: 220),
    radius: 0,
    toCenter: NSPoint(x: 300, y: 240),
    radius: 540,
    options: []
)

// Measurement grid keeps the icon related to the EQ graph.
let grid = NSBezierPath()
let gridInset: CGFloat = 150
for index in 0...8 {
    let fraction = CGFloat(index) / 8
    let x = iconRect.minX + gridInset + (iconRect.width - gridInset * 2) * fraction
    grid.move(to: NSPoint(x: x, y: iconRect.minY + 170))
    grid.line(to: NSPoint(x: x, y: iconRect.maxY - 170))
    let y = iconRect.minY + 210 + (iconRect.height - 420) * fraction
    grid.move(to: NSPoint(x: iconRect.minX + 150, y: y))
    grid.line(to: NSPoint(x: iconRect.maxX - 150, y: y))
}
color(0xFFFFFF, 0.042).setStroke()
grid.lineWidth = 2
grid.stroke()

// The same four-bar mark used in the header.
let barColors = [cyan, mint, color(0x86EFAC), color(0x5EEAD4)]
let barWidth: CGFloat = 74
let gap: CGFloat = 48
let baseline: CGFloat = 280
let heights: [CGFloat] = [220, 390, 290, 500]
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
let startX = (size - totalWidth) / 2

for (index, height) in heights.enumerated() {
    let rect = NSRect(
        x: startX + CGFloat(index) * (barWidth + gap),
        y: baseline,
        width: barWidth,
        height: height
    )
    let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    let barColor = barColors[index]

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = barColor.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 38
    shadow.shadowOffset = .zero
    shadow.set()

    let top = barColor.blended(withFraction: 0.18, of: .white) ?? barColor
    let bottom = barColor.blended(withFraction: 0.18, of: .black) ?? barColor
    NSGradient(starting: top, ending: bottom)!.draw(in: bar, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    bar.lineWidth = 2
    color(0x000000, 0.16).setStroke()
    bar.stroke()
}

// A quiet baseline ties the bars to the graph aesthetic.
let baselinePath = NSBezierPath()
baselinePath.move(to: NSPoint(x: 220, y: baseline - 2))
baselinePath.line(to: NSPoint(x: 804, y: baseline - 2))
color(0xFFFFFF, 0.10).setStroke()
baselinePath.lineWidth = 2
baselinePath.stroke()

// Crisp inner border.
let border = NSBezierPath(roundedRect: iconRect.insetBy(dx: 1, dy: 1), xRadius: 208, yRadius: 208)
color(0xFFFFFF, 0.12).setStroke()
border.lineWidth = 2
border.stroke()

NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff),
      let png = representation.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon.png")
try png.write(to: output)
print("Wrote \(output.path)")
