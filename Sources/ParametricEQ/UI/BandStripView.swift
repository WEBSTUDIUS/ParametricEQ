//  BandStripView.swift
//  ParametricEQ
//
//  Horizontal band selector beneath the graph.

import SwiftUI
import EQCore

/// Horizontal band selector under the graph. Shows colour, index, type,
/// frequency and gain; double-click toggles a band, right-click exposes
/// enable/delete actions.
struct BandStripView: View {
    @ObservedObject var model: AppModel

    /// Header row with band count/add button and the horizontally scrolling
    /// chip list.
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Text("BANDS")
                    .font(.ui(9.5, .semibold))
                    .tracking(1.6)
                    .foregroundStyle(Theme.subtext)
                Text("\(model.settings.bands.count)/\(EQBandLimits.maxBands)")
                    .font(.mono(8, .regular))
                    .foregroundStyle(Theme.faint)
                Spacer()
                if model.settings.bands.count < EQBandLimits.maxBands {
                    Button {
                        model.addBand()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 8.5, weight: .bold))
                            Text("ADD")
                                .font(.mono(8, .semibold))
                                .tracking(0.5)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accent.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("Add a parametric band")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Array(model.settings.bands.enumerated()), id: \.element.id) { index, band in
                        bandChip(index: index, band: band)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .background(PanelBackground())
    }

    /// Builds one compact band chip. The selected chip uses the band colour
    /// for its border; disabled bands are dimmed.
    private func bandChip(index: Int, band: EQBand) -> some View {
        let selected = model.selectedBandID == band.id
        let color = Theme.bandColor(index)

        return Button {
            model.select(band.id)
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(band.enabled ? 0.95 : 0.35))
                    .frame(width: 2.5, height: 25)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 4) {
                        Text(String(format: "%02d", index + 1))
                            .font(.mono(8, .semibold))
                            .foregroundStyle(color.opacity(band.enabled ? 1 : 0.4))
                        Text(band.type.shortName)
                            .font(.mono(7.5, .medium))
                            .foregroundStyle(Theme.faint)
                    }
                    Text(band.frequencyLabel)
                        .font(.mono(8.5, .medium))
                        .foregroundStyle(band.enabled ? Theme.text : Theme.faint)
                }

                if band.type.usesGain {
                    Text(band.gainLabel)
                        .font(.mono(7.5, .regular))
                        .foregroundStyle(Theme.subtext)
                        .frame(width: 38, alignment: .trailing)
                } else {
                    Image(systemName: band.enabled ? "waveform" : "eye.slash")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 38)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? color.opacity(0.105) : Theme.panelSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? color.opacity(0.5) : Theme.stroke, lineWidth: selected ? 1.2 : 1)
            )
            .opacity(band.enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.toggleBandEnabled(band.id)
            }
        )
        .contextMenu {
            Button(band.enabled ? "Disable" : "Enable") {
                model.toggleBandEnabled(band.id)
            }
            Button("Delete", role: .destructive) {
                model.select(band.id)
                model.removeSelectedBand()
            }
        }
        .help("\(band.type.displayName) · \(band.frequencyLabel)\(band.type.usesGain ? " · \(band.gainLabel)" : "") · Q \(String(format: "%.2f", band.q))")
    }
}
