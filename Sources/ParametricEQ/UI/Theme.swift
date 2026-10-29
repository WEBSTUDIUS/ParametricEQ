//  Theme.swift
//  ParametricEQ
//
//  Colour palette, typography and shared panel primitives.

import SwiftUI
import AppKit

/// Central colour/typography palette shared by every view. Keeping the
/// palette here makes light/dark experiments and future themes local.
enum Theme {
    /// Window background.
    static let background = Color(hex: 0x080A0C)
    static let backgroundLifted = Color(hex: 0x0B0F13)
    /// Standard panel fill.
    static let panel = Color(hex: 0x10151A)
    /// Raised panel fill used by overlays and toasts.
    static let panelRaised = Color(hex: 0x151B21)
    static let panelSoft = Color(hex: 0x0D1217)
    /// Hairline borders.
    static let stroke = Color.white.opacity(0.068)
    static let strokeStrong = Color.white.opacity(0.12)
    /// Primary text.
    static let text = Color(hex: 0xEDF2F5)
    /// Secondary labels.
    static let subtext = Color(hex: 0x8C99A6)
    /// Tertiary labels, grid text and disabled chrome.
    static let faint = Color(hex: 0x5B6772)
    /// Mint accent: active state, curve and primary actions.
    static let accent = Color(hex: 0x6EE7C7)
    static let accentSoft = Color(hex: 0x6EE7C7).opacity(0.16)
    /// Cyan accent: spectrum and secondary actions.
    static let cyan = Color(hex: 0x67E8F9)
    /// Warning/bypass colour.
    static let amber = Color(hex: 0xFBBF24)
    /// Destructive actions and errors.
    static let red = Color(hex: 0xFB7185)
    /// Live status dot.
    static let green = Color(hex: 0x4ADE80)

    /// Ten-colour palette; band colour is chosen by index so a band keeps
    /// its identity while dragging.
    static let bandColors: [Color] = [
        Color(hex: 0x67E8F9),
        Color(hex: 0x5EEAD4),
        Color(hex: 0x86EFAC),
        Color(hex: 0xBEF264),
        Color(hex: 0xFDE68A),
        Color(hex: 0xFDBA74),
        Color(hex: 0xFDA4AF),
        Color(hex: 0xF0ABFC),
        Color(hex: 0xC4B5FD),
        Color(hex: 0x93C5FD)
    ]

    /// Returns the palette colour for a band index, wrapping around.
    static func bandColor(_ index: Int) -> Color {
        bandColors[index % bandColors.count]
    }

    /// Reusable small monospaced font.
    static let monoSmall = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let monoValue = Font.system(size: 12, weight: .medium, design: .monospaced)
    /// Reusable uppercase section-label font.
    static let label = Font.system(size: 10, weight: .semibold, design: .default)
}

/// Hex convenience initialiser used by the palette.
extension Color {
    /// Creates an sRGB colour from `0xRRGGBB` and an optional alpha.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Typographic helpers.
extension Font {
    /// Regular UI font at a given size/weight.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Rounded display font for large values.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Monospaced font for numbers and codes.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Convenience container that applies padding and the standard panel
/// background.
/// Rounded panel background + hairline border.
struct PanelBackground: View {
    var radius: CGFloat = 16
    var raised: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(raised ? Theme.panelRaised : Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

/// Applies the standard panel padding and background to arbitrary content.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    var raised: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(PanelBackground(raised: raised))
    }
}

/// Uppercase tracked section header with optional right-aligned detail.
struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.ui(9.5, .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.subtext)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}

/// One-pixel horizontal separator using the shared stroke colour.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
    }
}

/// AppKit bridge for the window background.
extension NSColor {
    /// Opaque window background matching ``Theme/background``.
    static var appBackground: NSColor {
        NSColor(calibratedRed: 8 / 255, green: 10 / 255, blue: 12 / 255, alpha: 1)
    }
}
