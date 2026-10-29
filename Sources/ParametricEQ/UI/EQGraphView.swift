//  EQGraphView.swift
//  ParametricEQ
//
//  Interactive response graph, spectrum overlay and band drag handling.
//
//  Drawing layers are separate views so spectrum updates do not recompute the
//  response curve.

import SwiftUI
import AppKit
import EQCore

/// Maps between the graph’s visual coordinates and audio values.
/// X is logarithmic from 20 Hz to 20 kHz; Y is linear from -18 to +18 dB.
/// All drawing and hit-testing goes through these four conversions.
struct GraphPlot {
    let size: CGSize

    let leftInset: CGFloat = 46
    let rightInset: CGFloat = 18
    let topInset: CGFloat = 18
    let bottomInset: CGFloat = 30

    /// Drawable plot rectangle after reserving space for axis labels.
    var rect: CGRect {
        CGRect(
            x: leftInset,
            y: topInset,
            width: max(10, size.width - leftInset - rightInset),
            height: max(10, size.height - topInset - bottomInset)
        )
    }

    let minimumFrequency = 20.0
    let maximumFrequency = 20_000.0
    let minimumDB = -18.0
    let maximumDB = 18.0

    /// Log-frequency to horizontal pixel coordinate.
    func x(for frequency: Double) -> CGFloat {
        let f = frequency.clamped(to: minimumFrequency...maximumFrequency)
        let ratio = log10(f / minimumFrequency) / log10(maximumFrequency / minimumFrequency)
        return rect.minX + rect.width * CGFloat(ratio)
    }

    /// Decibels to vertical pixel coordinate (screen coordinates, top-down).
    func y(for decibels: Double) -> CGFloat {
        let db = decibels.clamped(to: minimumDB...maximumDB)
        let ratio = (maximumDB - db) / (maximumDB - minimumDB)
        return rect.minY + rect.height * CGFloat(ratio)
    }

    /// Inverse of ``x(for:)`` used by drag gestures.
    func frequency(for x: CGFloat) -> Double {
        let ratio = ((x - rect.minX) / rect.width).clamped(to: 0...1)
        return minimumFrequency * pow(maximumFrequency / minimumFrequency, Double(ratio))
    }

    /// Inverse of ``y(for:)`` used by drag gestures.
    func decibels(for y: CGFloat) -> Double {
        let ratio = ((y - rect.minY) / rect.height).clamped(to: 0...1)
        return maximumDB - Double(ratio) * (maximumDB - minimumDB)
    }
}

/// Memoises the 360-point response curve. The graph re-renders at 30 fps
/// for the spectrum; recomputing 360 × bands every frame would be wasteful.
final class ResponseCache {
    /// Settings used for the cached curve.
    private var lastSettings: EQSettings?
    /// Sample rate used for the cached curve.
    private var lastSampleRate: Double = 0
    /// Cached dB values.
    private var points: [Double] = []
    /// Resolution of the response curve.
    private let pointCount = 360

    /// Returns the cached curve, or recomputes it when settings/sample rate
    /// changed. Called from `EQGraphView.body`.
    func points(settings: EQSettings, sampleRate: Double) -> [Double] {
        if settings == lastSettings, abs(sampleRate - lastSampleRate) < 0.1 {
            return points
        }
        var calculated = [Double]()
        calculated.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let ratio = Double(index) / Double(pointCount - 1)
            let frequency = 20 * pow(1_000, ratio)
            calculated.append(settings.responseDB(at: frequency, sampleRate: sampleRate))
        }
        lastSettings = settings
        lastSampleRate = sampleRate
        points = calculated
        return calculated
    }
}

/// Interactive response graph. Layer order (bottom to top): surface, grid,
/// spectrum, response fill/line, selected-band guide, band handles, tooltips,
/// status badges and the engine overlay.
struct EQGraphView: View {
    @ObservedObject var model: AppModel
    @State private var responseCache = ResponseCache()
    @State private var hoveredBandID: UUID?
    @State private var dragState: BandDragState?

    /// Snapshot captured at drag start so frequency/gain/Q can be updated
    /// relative to the original values.
    private struct BandDragState {
        let bandID: UUID
        let frequency: Double
        let gain: Double
        let q: Double
    }

    /// Builds the graph geometry and all layers.
    var body: some View {
        GeometryReader { proxy in
            let plot = GraphPlot(size: proxy.size)
            ZStack(alignment: .topLeading) {
                GraphSurface()
                GridLayer(plot: plot)

                if model.showSpectrum {
                    SpectrumLayer(spectrum: model.spectrumModel, plot: plot)
                        .allowsHitTesting(false)
                }

                ResponseLayer(
                    points: responseCache.points(
                        settings: model.settings,
                        sampleRate: model.format?.sampleRate ?? 48_000
                    ),
                    plot: plot,
                    isBypassed: model.settings.bypass
                )
                .allowsHitTesting(false)

                if let selected = model.selectedBand {
                    SelectedBandGuide(
                        plot: plot,
                        frequency: selected.frequency,
                        color: bandColor(for: selected.id)
                    )
                    .allowsHitTesting(false)
                }

                bandHandles(plot: plot)
                if let tooltip = tooltipBand(plot: plot) {
                    BandTooltip(band: tooltip.band, color: tooltip.color)
                        .position(x: tooltip.x, y: tooltip.y)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                graphBadges(plot: plot)
                bottomOverlay(plot: plot)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: "eqGraph")
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
        }
    }

    /// Palette colour for a band id.
    private func bandColor(for id: UUID) -> Color {
        guard let index = model.settings.bands.firstIndex(where: { $0.id == id }) else {
            return Theme.accent
        }
        return Theme.bandColor(index)
    }

    /// Creates one draggable handle per band, with hover tooltip and context menu.
    /// Handles are positioned by frequency and (for gain filters) gain.
    @ViewBuilder
    private func bandHandles(plot: GraphPlot) -> some View {
        ForEach(Array(model.settings.bands.enumerated()), id: \.element.id) { index, band in
            let x = plot.x(for: band.frequency)
            let y = band.type.usesGain ? plot.y(for: band.gain) : plot.y(for: 0)
            let selected = model.selectedBandID == band.id
            let color = Theme.bandColor(index)

            BandHandle(
                number: index + 1,
                color: color,
                selected: selected,
                enabled: band.enabled,
                hovered: hoveredBandID == band.id
            )
            .position(x: x, y: y)
            .onHover { hovering in
                hoveredBandID = hovering ? band.id : (hoveredBandID == band.id ? nil : hoveredBandID)
            }
            .gesture(dragGesture(for: band, plot: plot))
            .contextMenu {
                Button("Reset Gain & Q") {
                    model.select(band.id)
                    model.resetSelectedBand()
                }
                Button(band.enabled ? "Disable Band" : "Enable Band") {
                    model.toggleBandEnabled(band.id)
                }
                Divider()
                Button("Delete Band", role: .destructive) {
                    model.select(band.id)
                    model.removeSelectedBand()
                }
            }
            .help(handleTooltip(band: band))

        }
    }

    /// Accessibility/help text describing the drag modifiers.
    private func handleTooltip(band: EQBand) -> String {
        let action = band.type.usesGain ? "Drag to set frequency and gain." : "Drag horizontally for frequency, vertically for Q."
        return "\(band.type.displayName) · \(band.frequencyLabel) · \(band.gainLabel) · Q \(String(format: "%.2f", band.q))\n\(action) Hold ⇧ while dragging to change Q."
    }

    /// Drag behaviour: horizontal = frequency, vertical = gain; ⇧-drag or
    /// a non-gain filter uses vertical motion for Q.
    private func dragGesture(for band: EQBand, plot: GraphPlot) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("eqGraph"))
            .onChanged { gesture in
                if dragState?.bandID != band.id {
                    dragState = BandDragState(
                        bandID: band.id,
                        frequency: band.frequency,
                        gain: band.gain,
                        q: band.q
                    )
                    model.select(band.id)
                }
                guard let start = dragState else { return }

                let frequency = plot.frequency(for: gesture.location.x)
                model.updateBand(id: band.id) { current in
                    current.frequency = frequency
                    if NSEvent.modifierFlags.contains(.shift) {
                        current.q = start.q * pow(2, -Double(gesture.translation.height) / 85)
                    } else if band.type.usesGain {
                        current.gain = plot.decibels(for: gesture.location.y)
                    } else {
                        current.q = start.q * pow(2, -Double(gesture.translation.height) / 85)
                    }
                }
            }
            .onEnded { _ in
                dragState = nil
            }
    }

    /// Chooses the hovered band, falling back to the selected band, and
    /// returns a clamped screen position. Disabled in snapshot mode.
    private func tooltipBand(plot: GraphPlot) -> (band: EQBand, color: Color, x: CGFloat, y: CGFloat)? {
        guard !CommandLine.arguments.contains("--snapshot") else { return nil }
        let band: EQBand?
        if let hoveredBandID,
           let hovered = model.settings.bands.first(where: { $0.id == hoveredBandID }) {
            band = hovered
        } else {
            band = model.selectedBand
        }
        guard let band,
              let index = model.settings.bands.firstIndex(where: { $0.id == band.id }) else { return nil }
        let x = plot.x(for: band.frequency)
        let y = band.type.usesGain ? plot.y(for: band.gain) : plot.y(for: 0)
        return (
            band,
            Theme.bandColor(index),
            min(max(x, 96), plot.rect.maxX - 96),
            max(y - 35, plot.rect.minY + 16)
        )
    }

    /// Top-right active/bypass/spectrum badges.
    @ViewBuilder
    private func graphBadges(plot: GraphPlot) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Text("\(model.activeBandCount) ACTIVE")
                .font(.mono(8.5, .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.faint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.25)))

            if model.settings.bypass {
                Text("BYPASSED")
                    .font(.mono(8.5, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.amber.opacity(0.12)))
            }
            if model.showSpectrum {
                HStack(spacing: 4) {
                    Circle().fill(Theme.cyan).frame(width: 4, height: 4)
                    Text("SPECTRUM")
                        .font(.mono(8, .medium))
                        .tracking(0.8)
                        .foregroundStyle(Theme.faint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .frame(width: plot.size.width, alignment: .trailing)
        .allowsHitTesting(false)
    }

    /// Engine status cards anchored to the bottom of the graph.
    @ViewBuilder
    private func bottomOverlay(plot: GraphPlot) -> some View {
        VStack {
            Spacer()
            Group {
                switch model.engineState {
                case .idle:
                    idleOverlay
                case .starting:
                    startingOverlay
                case .failed(let message):
                    errorOverlay(message)
                case .running:
                    EmptyView()
                }
            }
            .padding(.bottom, 38)
        }
        .frame(width: plot.size.width, height: plot.size.height)
        .animation(.easeInOut(duration: 0.22), value: model.engineState)
    }

    /// Power-off card with a one-click Enable action.
    private var idleOverlay: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 34, height: 34)
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasCompletedOnboarding ? "System audio is off" : "Welcome to Parametric EQ")
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.text)
                Text("Turn it on to put every app through this curve.")
                    .font(.ui(10.5, .regular))
                    .foregroundStyle(Theme.subtext)
            }
            Spacer(minLength: 16)
            ActionButton(title: "Enable", icon: "power", prominent: true) {
                model.enable()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 500)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panelRaised.opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        )
    }

    /// Connecting spinner, or the permission-timeout recovery card.
    private var startingOverlay: some View {
        Group {
            if model.startupTimedOut {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for system audio access")
                            .font(.ui(12, .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Allow Parametric EQ in System Settings, then retry.")
                            .font(.ui(10, .regular))
                            .foregroundStyle(Theme.subtext)
                    }
                    Spacer(minLength: 10)
                    ActionButton(title: "Settings", icon: "gear", tint: Theme.amber) {
                        model.openPrivacySettings()
                    }
                    ActionButton(title: "Retry", icon: "arrow.clockwise", prominent: true) {
                        model.retry()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 560)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.panelRaised.opacity(0.98))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.amber.opacity(0.24), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                )
            } else {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                    Text("Connecting to system audio…")
                        .font(.ui(11, .medium))
                        .foregroundStyle(Theme.subtext)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.panelRaised.opacity(0.97)).overlay(Capsule().stroke(Theme.stroke, lineWidth: 1)))
            }
        }
    }

    /// Failure card with Settings and Retry actions.
    private func errorOverlay(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("System audio access needed")
                    .font(.ui(12, .semibold))
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(.ui(10, .regular))
                    .foregroundStyle(Theme.subtext)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            ActionButton(title: "Settings", icon: "gear", tint: Theme.amber) {
                model.openPrivacySettings()
            }
            ActionButton(title: "Retry", icon: "arrow.clockwise", prominent: true) {
                model.retry()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 640)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panelRaised.opacity(0.98))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.amber.opacity(0.24), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        )
    }
}

// MARK: - Drawing layers

/// Rounded graph background and subtle accent glow.
private struct GraphSurface: View {
    /// Paints the graph background and accent glow.
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0D1216), Color(hex: 0x080A0C)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RadialGradient(
                colors: [Theme.accent.opacity(0.045), .clear],
                center: UnitPoint(x: 0.46, y: 0.72),
                startRadius: 10,
                endRadius: 330
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Draws log frequency lines, dB lines and axis labels.
private struct GridLayer: View {
    let plot: GraphPlot

    private let majorFrequencies: [(Double, String)] = [
        (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1_000, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k"), (20_000, "20k")
    ]
    private let minorFrequencies: [Double] = [30, 70, 150, 300, 700, 1_500, 3_000, 7_000, 15_000]
    private let decibelLines = [-18, -12, -6, 0, 6, 12, 18]

    /// Paints grid lines and labels.
    var body: some View {
        Canvas { context, _ in
            let rect = plot.rect

            for frequency in minorFrequencies {
                var path = Path()
                let x = plot.x(for: frequency)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(path, with: .color(Color.white.opacity(0.032)), lineWidth: 1)
            }

            for (frequency, _) in majorFrequencies {
                var path = Path()
                let x = plot.x(for: frequency)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.stroke(path, with: .color(Color.white.opacity(0.058)), lineWidth: 1)
            }

            for db in decibelLines {
                var path = Path()
                let y = plot.y(for: Double(db))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                let opacity = db == 0 ? 0.16 : 0.055
                context.stroke(path, with: .color(Color.white.opacity(opacity)), lineWidth: db == 0 ? 1.2 : 1)
            }

            for (frequency, label) in majorFrequencies {
                let x = plot.x(for: frequency)
                context.draw(
                    Text(label)
                        .font(.mono(8, .regular))
                        .foregroundColor(Theme.faint),
                    at: CGPoint(x: x, y: rect.maxY + 10),
                    anchor: .top
                )
            }

            for db in decibelLines {
                let y = plot.y(for: Double(db))
                let label = db > 0 ? "+\(db)" : "\(db)"
                context.draw(
                    Text(label)
                        .font(.mono(8, .regular))
                        .foregroundColor(Theme.faint),
                    at: CGPoint(x: rect.minX - 8, y: y),
                    anchor: .trailing
                )
            }

        }
    }
}

/// Draws the smoothed spectrum fill/line from ``SpectrumModel``.
private struct SpectrumLayer: View {
    @ObservedObject var spectrum: SpectrumModel
    let plot: GraphPlot

    /// Paints the spectrum fill and line.
    var body: some View {
        Canvas { context, _ in
            let values = spectrum.values
            guard values.count > 2 else { return }
            let rect = plot.rect
            context.clip(to: Path(rect))

            var path = Path()
            for index in values.indices {
                let ratio = Double(index) / Double(values.count - 1)
                let x = rect.minX + rect.width * CGFloat(ratio)
                let normalized = CGFloat(values[index]).clamped(to: 0...1)
                let y = rect.maxY - rect.height * 0.88 * normalized
                if index == values.startIndex {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            var fill = path
            fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            fill.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [Theme.cyan.opacity(0.07), Theme.cyan.opacity(0.004)]),
                    startPoint: CGPoint(x: 0, y: rect.minY),
                    endPoint: CGPoint(x: 0, y: rect.maxY)
                )
            )

            var glow = context
            glow.addFilter(.shadow(color: Theme.cyan.opacity(0.22), radius: 5))
            glow.stroke(path, with: .color(Theme.cyan.opacity(0.32)), style: StrokeStyle(lineWidth: 1.1, lineJoin: .round))
        }
    }
}

/// Draws the combined EQ response curve and its gradient fill.
private struct ResponseLayer: View {
    let points: [Double]
    let plot: GraphPlot
    let isBypassed: Bool

    private var accent: Color { isBypassed ? Theme.faint : Theme.accent }

    /// Paints the response fill and line.
    var body: some View {
        Canvas { context, _ in
            guard points.count > 1 else { return }
            let rect = plot.rect
            context.clip(to: Path(rect))

            var line = Path()
            for index in points.indices {
                let ratio = Double(index) / Double(points.count - 1)
                let x = rect.minX + rect.width * CGFloat(ratio)
                let y = plot.y(for: points[index])
                if index == points.startIndex {
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let zeroY = plot.y(for: 0)
            var fill = line
            fill.addLine(to: CGPoint(x: rect.maxX, y: zeroY))
            fill.addLine(to: CGPoint(x: rect.minX, y: zeroY))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [accent.opacity(isBypassed ? 0.025 : 0.15), accent.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: rect.minY),
                    endPoint: CGPoint(x: 0, y: rect.maxY)
                )
            )

            var glow = context
            glow.addFilter(.shadow(color: accent.opacity(isBypassed ? 0.0 : 0.42), radius: 6))
            glow.stroke(
                line,
                with: .color(accent.opacity(isBypassed ? 0.45 : 0.98)),
                style: StrokeStyle(lineWidth: isBypassed ? 1.4 : 2.1, lineCap: .round, lineJoin: .round, dash: isBypassed ? [4, 4] : [])
            )
        }
    }
}

/// Dashed vertical guide from the selected handle to the bottom axis.
private struct SelectedBandGuide: View {
    let plot: GraphPlot
    let frequency: Double
    let color: Color

    /// Paints the selected-band guide.
    var body: some View {
        Canvas { context, _ in
            let x = plot.x(for: frequency)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.y(for: 0)))
            path.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.24), color.opacity(0.0)]),
                    startPoint: CGPoint(x: 0, y: plot.rect.minY),
                    endPoint: CGPoint(x: 0, y: plot.rect.maxY)
                ),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )
        }
    }
}

/// Draggable numbered handle with selected/hover/disabled states.
private struct BandHandle: View {
    let number: Int
    let color: Color
    let selected: Bool
    let enabled: Bool
    let hovered: Bool

    /// Renders the handle circle/number.
    var body: some View {
        ZStack {
            if selected {
                Circle()
                    .fill(color.opacity(0.13))
                    .frame(width: 34, height: 34)
                    .blur(radius: 5)
            }
            Circle()
                .fill(Theme.background.opacity(0.96))
                .frame(width: selected ? 21 : 17, height: selected ? 21 : 17)
                .overlay(
                    Circle().stroke(
                        color.opacity(enabled ? (selected ? 1 : 0.75) : 0.3),
                        style: StrokeStyle(lineWidth: selected ? 2.2 : 1.5, dash: enabled ? [] : [2.5, 2.5])
                    )
                )
                .shadow(color: selected ? color.opacity(0.35) : .black.opacity(0.3), radius: selected ? 7 : 2, y: 1)

            Text("\(number)")
                .font(.mono(selected ? 8.5 : 7.5, .semibold))
                .foregroundStyle(enabled ? color : Theme.faint)
        }
        .frame(width: 36, height: 36)
        .scaleEffect(hovered ? 1.08 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.72), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contentShape(Circle())
    }
}

/// Compact hover readout (type, frequency, gain, Q).
private struct BandTooltip: View {
    let band: EQBand
    let color: Color

    /// Renders the hover capsule.
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(band.type.shortName)
                .font(.mono(8.5, .semibold))
                .foregroundStyle(color)
            Text(band.frequencyLabel)
                .font(.mono(9, .medium))
                .foregroundStyle(Theme.text)
            if band.type.usesGain {
                Text(band.gainLabel)
                    .font(.mono(9, .medium))
                    .foregroundStyle(Theme.subtext)
            }
            Text("Q \(String(format: "%.2f", band.q))")
                .font(.mono(8.5, .regular))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Theme.panelRaised)
                .overlay(Capsule().stroke(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        )
    }
}
