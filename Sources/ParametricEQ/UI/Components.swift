//  Components.swift
//  ParametricEQ
//
//  Reusable SwiftUI controls (sliders, switches, buttons, meter, toast).

import SwiftUI
import AppKit
import EQCore

/// Custom horizontal slider used everywhere instead of the stock control.
/// Drag anywhere on the track to set the value; the thumb is purely visual.
struct ThinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var accent: Color = Theme.accent
    var trackHeight: CGFloat = 4
    var thumbSize: CGFloat = 11
    var isEnabled: Bool = true

    @State private var isDragging = false

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbX = (width - thumbSize) * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.075))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.75), accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackHeight, width * fraction), height: trackHeight)
                    .shadow(color: accent.opacity(isEnabled ? 0.25 : 0), radius: 4)

                Circle()
                    .fill(Theme.text)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(Circle().stroke(accent, lineWidth: isDragging ? 2 : 1.2))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: thumbX)
                    .scaleEffect(isDragging ? 1.12 : 1)
            }
            .frame(height: thumbSize + 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        isDragging = true
                        let position = (gesture.location.x / max(width, 1)).clamped(to: 0...1)
                        value = range.lowerBound + position * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: thumbSize + 4)
        .opacity(isEnabled ? 1 : 0.35)
        .allowsHitTesting(isEnabled)
    }
}

/// Wraps ``ThinSlider`` with a logarithmic mapping. Used for frequency and
/// Q, where equal pixel distances should represent equal ratios.
struct LogSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var accent: Color = Theme.accent
    var isEnabled: Bool = true

    private var normalized: Binding<Double> {
        Binding(
            get: {
                guard range.lowerBound > 0, value > 0 else { return 0 }
                return (log(value / range.lowerBound) / log(range.upperBound / range.lowerBound)).clamped(to: 0...1)
            },
            set: { newValue in
                let value = range.lowerBound * pow(range.upperBound / range.lowerBound, newValue.clamped(to: 0...1))
                self.value = value
            }
        )
    }

    var body: some View {
        ThinSlider(value: normalized, range: 0...1, accent: accent, isEnabled: isEnabled)
    }
}

/// One labelled parameter row: title, formatted value, unit and an injected
/// slider. Keeps the inspector visually consistent.
struct ParameterControl<Slider: View>: View {
    let title: String
    let value: String
    var unit: String?
    var accent: Color = Theme.accent
    var isEnabled: Bool = true
    var customValue: AnyView? = nil
    @ViewBuilder var slider: () -> Slider

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.ui(11, .medium))
                    .foregroundStyle(isEnabled ? Theme.subtext : Theme.faint)
                Spacer(minLength: 8)
                if let customValue {
                    customValue
                } else {
                    Text(value)
                        .font(.mono(11.5, .medium))
                        .foregroundStyle(isEnabled ? Theme.text : Theme.faint)
                    if let unit {
                        Text(unit)
                            .font(.ui(9, .medium))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            slider()
        }
        .opacity(isEnabled ? 1 : 0.75)
    }
}

/// Numeric interpretation of an editable inspector field.
enum NumericParameterKind {
    case frequency
    case gain
    case q

    var unit: String {
        switch self {
        case .frequency: return "Hz"
        case .gain: return "dB"
        case .q: return ""
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .frequency: return String(format: "%.2f", value)
        case .gain: return String(format: "%+.2f", value)
        case .q: return String(format: "%.2f", value)
        }
    }

    func parse(_ raw: String) -> Double? {
        var text = raw
            .lowercased()
            .replacingOccurrences(of: "hz", with: "")
            .replacingOccurrences(of: "db", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-")
        guard !text.isEmpty else { return nil }
        if text.hasSuffix("k") {
            text.removeLast()
            return Double(text).map { $0 * 1_000 }
        }
        if text.hasPrefix("+") { text.removeFirst() }
        return Double(text)
    }
}

/// Small editable numeric field used in the inspector. It accepts plain
/// numbers and shortcuts such as `1.2k` / `1.2 kHz`, commits on Return or
/// focus loss, clamps to the supplied range and reverts invalid input.
struct NumericParameterField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let kind: NumericParameterKind
    var accent: Color = Theme.accent

    @State private var text: String
    @FocusState private var focused: Bool

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        kind: NumericParameterKind,
        accent: Color = Theme.accent
    ) {
        self._value = value
        self.range = range
        self.kind = kind
        self.accent = accent
        self._text = State(initialValue: kind.format(value.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 3) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.mono(11.5, .medium))
                .foregroundStyle(Theme.text)
                .frame(width: kind == .frequency ? 72 : 56)
                .focused($focused)
                .onSubmit {
                    commit()
                    focused = false
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onChange(of: value) { _, newValue in
                    if !focused { text = kind.format(newValue) }
                }
                .help("Type an exact value and press Return")

            if !kind.unit.isEmpty {
                Text(kind.unit)
                    .font(.ui(9, .medium))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(focused ? accent.opacity(0.12) : Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(focused ? accent.opacity(0.45) : Theme.stroke, lineWidth: 1)
                )
        )
        .onAppear { text = kind.format(value) }
    }

    private func commit() {
        guard let parsed = kind.parse(text), parsed.isFinite else {
            text = kind.format(value)
            return
        }
        let clamped = parsed.clamped(to: range)
        if clamped != value { value = clamped }
        text = kind.format(clamped)
    }
}

/// Compact capsule switch used for band enable, limiter and other binary
/// inspector options.
struct MiniSwitch: View {
    @Binding var isOn: Bool
    var accent: Color = Theme.accent
    var isEnabled: Bool = true

    var body: some View {
        Button {
            guard isEnabled else { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                isOn.toggle()
            }
        } label: {
            Capsule()
                .fill(isOn ? accent.opacity(0.85) : Color.white.opacity(0.12))
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? Theme.background : Theme.subtext)
                        .frame(width: 14, height: 14)
                        .padding(3)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Small square icon button with hover feedback; used in headers and
/// toolbars.
struct IconButton: View {
    let systemName: String
    var isActive: Bool = false
    var help: String = ""
    var size: CGFloat = 30
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isActive ? Theme.accent : (hovering ? Theme.text : Theme.subtext))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.065) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Pill-shaped text/icon button with a prominent (filled) or subtle
/// (outlined) style.
struct ActionButton: View {
    let title: String
    var icon: String?
    var tint: Color = Theme.accent
    var prominent: Bool = false
    var isEnabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(title)
                    .font(.ui(11, .semibold))
            }
            .foregroundStyle(prominent ? Theme.background : tint)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(hovering ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(prominent ? Color.clear : tint.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
    }
}

/// Coloured dot with a pulsing ring for `starting`/`running` states.
struct StatusDot: View {
    let state: AudioEngineState
    @State private var pulse = false

    private var color: Color {
        switch state {
        case .running: return Theme.green
        case .starting: return Theme.amber
        case .failed: return Theme.red
        case .idle: return Theme.faint
        }
    }

    var body: some View {
        ZStack {
            if state.isRunning || state.isStarting {
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .scaleEffect(pulse ? 2.6 : 0.9)
                    .opacity(pulse ? 0 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .onChange(of: state) { _, _ in
            pulse = false
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Thin peak meter driven by ``SpectrumModel/level``.
struct LevelMeter: View {
    @ObservedObject var spectrum: SpectrumModel
    var width: CGFloat = 64

    var body: some View {
        GeometryReader { geometry in
            let level = CGFloat(spectrum.level).clamped(to: 0...1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.green, Theme.amber, Theme.red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(1, geometry.size.width * level))
            }
        }
        .frame(width: width, height: 3)
        .animation(.linear(duration: 0.08), value: spectrum.level)
    }
}

/// Transient confirmation capsule shown above the footer.
struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.ui(11.5, .medium))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Theme.panelRaised)
                .overlay(Capsule().stroke(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        )
    }
}

/// Shown in the inspector if no band is selected (e.g. after deleting the
/// last selection).
struct EmptyBandPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.faint)
            Text("Select a band")
                .font(.ui(12, .medium))
                .foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}
