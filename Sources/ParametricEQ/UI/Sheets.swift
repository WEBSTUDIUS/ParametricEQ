//  Sheets.swift
//  ParametricEQ
//
//  Save-preset and AutoEq-import modal sheets.

import SwiftUI
import AppKit
import EQCore

/// Small modal sheet that asks for a preset name and delegates saving to
/// ``AppModel/commitSavePreset()``.
struct SavePresetSheet: View {
    @ObservedObject var model: AppModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SAVE PRESET")
                        .font(.ui(9.5, .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.accent)
                    Text("Keep this curve for later.")
                        .font(.ui(11, .regular))
                        .foregroundStyle(Theme.subtext)
                }
                Spacer()
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.faint)
            }

            TextField("Preset name", text: $model.presetNameDraft)
                .textFieldStyle(.plain)
                .font(.ui(13, .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.panelSoft)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.strokeStrong, lineWidth: 1))
                )
                .focused($nameFocused)
                .onSubmit { model.commitSavePreset() }

            HStack {
                Spacer()
                ActionButton(title: "Cancel", tint: Theme.subtext) {
                    model.isShowingSavePreset = false
                }
                ActionButton(title: "Save", icon: "checkmark", prominent: true) {
                    model.commitSavePreset()
                }
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.backgroundLifted)
        .onAppear { nameFocused = true }
    }
}

/// Modal AutoEq/Equalizer APO importer. Accepts pasted text or a file,
/// shows parser errors inline and applies the resulting curve as a preset.
struct ImportPresetSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("IMPORT PARAMETRIC PRESET")
                        .font(.ui(9.5, .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.cyan)
                    Text("Paste AutoEq / Equalizer APO text, or choose a .txt file.")
                        .font(.ui(11, .regular))
                        .foregroundStyle(Theme.subtext)
                }
                Spacer()
                Button {
                    model.importFromFile()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                        Text("FILE")
                            .font(.mono(8.5, .semibold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            TextEditor(text: $model.importText)
                .font(.mono(10, .regular))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.panelSoft)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                )
                .frame(minHeight: 190)

            if let error = model.importError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(error)
                        .font(.ui(10, .medium))
                        .lineLimit(2)
                }
                .foregroundStyle(Theme.red)
            }

            Text("Supported: Preamp and Filter lines with PK, LS/LSC, HS/HSC, LP, HP, NO or BP.")
                .font(.ui(9, .regular))
                .foregroundStyle(Theme.faint)

            HStack {
                Spacer()
                ActionButton(title: "Cancel", tint: Theme.subtext) {
                    model.isShowingImport = false
                }
                ActionButton(title: "Import", icon: "arrow.down.circle", tint: Theme.cyan, prominent: true) {
                    model.importFromText()
                }
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Theme.backgroundLifted)
    }
}
