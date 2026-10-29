//  ContentView.swift
//  ParametricEQ
//
//  Root window layout and sheet/toast composition.

import SwiftUI
import AppKit

/// Root layout: header, graph + band strip, inspector and footer. It also
/// hosts the save/import sheets and the transient toast.
struct ContentView: View {
    @ObservedObject var model: AppModel

    /// Composes the main window and attaches sheet/activation observers.
    var body: some View {
        ZStack {
            Theme.background
            backgroundGlow

            VStack(spacing: 0) {
                HeaderBar(model: model)

                HStack(alignment: .top, spacing: 13) {
                    VStack(spacing: 13) {
                        EQGraphView(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        BandStripView(model: model)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    InspectorView(model: model)
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .frame(maxHeight: .infinity)

                FooterBar(model: model)
            }

            if let toast = model.toast {
                VStack {
                    Spacer()
                    ToastView(message: toast)
                        .padding(.bottom, 38)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .frame(minWidth: 1_000, minHeight: 670)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $model.isShowingSavePreset) {
            SavePresetSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingImport) {
            ImportPresetSheet(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLogin()
        }
    }

    /// Decorative radial glows. Purely visual and hit-testing disabled.
    private var backgroundGlow: some View {
        ZStack {
            RadialGradient(
                colors: [Theme.accent.opacity(0.055), .clear],
                center: UnitPoint(x: 0.82, y: 0.04),
                startRadius: 20,
                endRadius: 480
            )
            RadialGradient(
                colors: [Theme.cyan.opacity(0.025), .clear],
                center: UnitPoint(x: 0.12, y: 0.95),
                startRadius: 10,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
