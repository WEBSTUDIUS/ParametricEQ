//  InspectorView.swift
//  ParametricEQ
//
//  Selected-band editor and master output controls.

import SwiftUI
import EQCore

/// Right-side editor. Shows the selected band’s filter type, frequency,
/// gain and Q, followed by global preamp/balance/limiter controls.
struct InspectorView: View {
    @ObservedObject var model: AppModel

    /// Index of the selected band, used to pick its colour.
    private var selectedIndex: Int? { model.selectedBandIndex }
    /// Selected band value resolved through the model.
    private var selectedBand: EQBand? { model.selectedBand }
    /// Colour associated with the selected band.
    private var accent: Color {
        guard let index = selectedIndex else { return Theme.accent }
        return Theme.bandColor(index)
    }

    /// Scrollable inspector layout.
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                if let band = selectedBand, let index = selectedIndex {
                    bandSection(band: band, index: index)
                } else {
                    Panel {
                        EmptyBandPlaceholder()
                    }
                }

                outputSection
            }
            .padding(.bottom, 4)
        }
        .frame(width: 322)
    }

    // MARK: - Band

    /// Band header (enable/type), large frequency readout, three parameter
    /// sliders and reset/delete/add actions.
    private func bandSection(band: EQBand, index: Int) -> some View {
        Panel(padding: 15) {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text("BAND \(String(format: "%02d", index + 1))")
                        .font(.mono(9, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(accent)
                    Spacer()

                    MiniSwitch(
                        isOn: Binding(
                            get: { band.enabled },
                            set: { newValue in
                                model.updateBand(id: band.id) { $0.enabled = newValue }
                            }
                        ),
                        accent: accent
                    )

                    Menu {
                        ForEach(EQFilterType.allCases) { type in
                            Button {
                                model.setType(type)
                            } label: {
                                if type == band.type {
                                    Label(type.displayName, systemImage: "checkmark")
                                } else {
                                    Text(type.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(band.type.displayName.uppercased())
                                .font(.mono(8, .semibold))
                                .tracking(0.5)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(Theme.subtext)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.stroke, lineWidth: 1)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(band.frequencyLabel)
                        .font(.display(27, .semibold))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    Spacer()
                    Text(band.type.shortName)
                        .font(.mono(8, .semibold))
                        .tracking(0.7)
                        .foregroundStyle(accent.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accent.opacity(0.09)))
                }

                VStack(spacing: 13) {
                    ParameterControl(
                        title: "FREQUENCY",
                        value: "",
                        accent: accent,
                        customValue: AnyView(
                            NumericParameterField(
                                value: Binding(
                                    get: { band.frequency },
                                    set: { model.setFrequency($0) }
                                ),
                                range: 20...20_000,
                                kind: .frequency,
                                accent: accent
                            )
                        )
                    ) {
                        LogSlider(
                            value: Binding(
                                get: { band.frequency },
                                set: { model.setFrequency($0) }
                            ),
                            range: 20...20_000,
                            accent: accent
                        )
                    }

                    ParameterControl(
                        title: "GAIN",
                        value: band.type.usesGain ? "" : "—",
                        accent: accent,
                        isEnabled: band.type.usesGain,
                        customValue: band.type.usesGain
                            ? AnyView(
                                NumericParameterField(
                                    value: Binding(
                                        get: { band.gain },
                                        set: { model.setGain($0) }
                                    ),
                                    range: -18...18,
                                    kind: .gain,
                                    accent: accent
                                )
                            )
                            : nil
                    ) {
                        ThinSlider(
                            value: Binding(
                                get: { band.gain },
                                set: { model.setGain($0) }
                            ),
                            range: -18...18,
                            accent: accent,
                            isEnabled: band.type.usesGain
                        )
                    }

                    ParameterControl(
                        title: "Q / BANDWIDTH",
                        value: "",
                        accent: accent,
                        customValue: AnyView(
                            NumericParameterField(
                                value: Binding(
                                    get: { band.q },
                                    set: { model.setQ($0) }
                                ),
                                range: 0.1...18,
                                kind: .q,
                                accent: accent
                            )
                        )
                    ) {
                        LogSlider(
                            value: Binding(
                                get: { band.q },
                                set: { model.setQ($0) }
                            ),
                            range: 0.1...18,
                            accent: accent
                        )
                    }
                }

                HStack(spacing: 7) {
                    ActionButton(title: "Reset", icon: "arrow.counterclockwise", tint: Theme.subtext) {
                        model.resetSelectedBand()
                    }
                    ActionButton(title: "Delete", icon: "trash", tint: Theme.red, isEnabled: model.settings.bands.count > 1) {
                        model.removeSelectedBand()
                    }
                    Spacer()
                    ActionButton(title: "Add", icon: "plus", tint: Theme.accent, isEnabled: model.settings.bands.count < EQBandLimits.maxBands) {
                        model.addBand()
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 8.5, weight: .medium))
                    Text("Drag the graph point or type exact values. Hold ⇧ to shape Q.")
                        .font(.ui(9, .regular))
                }
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Output

    /// Master controls: preamp, stereo balance and limiter.
    private var outputSection: some View {
        Panel(padding: 15) {
            VStack(spacing: 14) {
                SectionLabel(text: "Output", trailing: "MASTER")

                ParameterControl(
                    title: "PREAMP",
                    value: String(format: "%+.1f", model.settings.preamp),
                    unit: "dB",
                    accent: Theme.accent
                ) {
                    ThinSlider(
                        value: Binding(
                            get: { model.settings.preamp },
                            set: { model.setPreamp($0) }
                        ),
                        range: -24...12,
                        accent: Theme.accent
                    )
                }

                VStack(spacing: 7) {
                    HStack {
                        Text("BALANCE")
                            .font(.ui(11, .medium))
                            .foregroundStyle(Theme.subtext)
                        Spacer()
                        Text(balanceLabel)
                            .font(.mono(11.5, .medium))
                            .foregroundStyle(Theme.text)
                    }
                    ThinSlider(
                        value: Binding(
                            get: { model.settings.balance },
                            set: { model.setBalance($0) }
                        ),
                        range: -1...1,
                        accent: Theme.accent
                    )
                    HStack {
                        Text("L")
                            .font(.mono(8, .medium))
                            .foregroundStyle(Theme.faint)
                        Spacer()
                        Text("R")
                            .font(.mono(8, .medium))
                            .foregroundStyle(Theme.faint)
                    }
                }

                Hairline()

                ToggleRow(
                    title: "Limiter",
                    subtitle: "Transparent look-ahead clipping guard",
                    isOn: $model.settings.limiter,
                    accent: Theme.accent
                )
            }
        }
    }

    /// Formats balance as CENTER / L n% / R n%.
    private var balanceLabel: String {
        let value = model.settings.balance
        if abs(value) < 0.01 { return "CENTER" }
        return value < 0 ? "L \(Int(abs(value) * 100))%" : "R \(Int(value * 100))%"
    }


}

/// Label + subtitle + switch row used for limiter and other toggles.
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var accent: Color = Theme.accent

    /// Row layout for ``ToggleRow``.
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.ui(11, .medium))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.ui(9, .regular))
                    .foregroundStyle(Theme.faint)
            }
            Spacer()
            MiniSwitch(isOn: $isOn, accent: accent)
        }
    }
}
