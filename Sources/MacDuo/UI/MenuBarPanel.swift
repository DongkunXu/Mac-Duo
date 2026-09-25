import MacDuoKit
import SwiftUI

struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: "Mac Duo").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            StatusSummary(model: model)

            if let spec = model.releaseAngleParameter, case .continuous(let range, _) = spec.kind {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent(spec.name, value: model.releaseAngle.formatted(.number.precision(.fractionLength(1))) + "°")
                    // Stepping happens in `ParameterValues`; a stepped Slider would draw tick marks.
                    Slider(value: Binding(get: { model.releaseAngle }, set: { model.setReleaseAngle($0) }), in: range)
                }
                .font(.callout)
                .monospacedDigit()
            }

            Divider()

            Menu("Apply preset") {
                Section("Built-in") {
                    ForEach(model.builtInPresets) { preset in
                        Button(preset.name) { model.apply(preset) }
                    }
                }
                if !model.userPresets.isEmpty {
                    Section("Saved") {
                        ForEach(model.userPresets) { preset in
                            Button(preset.name) { model.apply(preset) }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                    .help("Shortcut: \(model.pauseShortcut)")
                Spacer()
                Button("Settings…") {
                    openWindow(id: SettingsView.windowID)
                    NSApp.activate()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Live angle, deviation and run state, shared by the menu bar panel and the settings window.
struct StatusSummary: View {
    let model: AppModel
    @State private var viewerID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Lid angle", value: angleText)
            LabeledContent("Deviation", value: deviationText)
            LabeledContent("State", value: stateText)
            if let problem = model.visibleProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .monospacedDigit()
        // The model refreshes the live values only while a readout is on screen.
        .onAppear { model.liveReadoutAppeared(viewerID) }
        .onDisappear { model.liveReadoutDisappeared(viewerID) }
    }

    private var angleText: String {
        guard let angle = model.liveAngle else { return "—" }
        return angle.formatted(.number.precision(.fractionLength(2))) + "°"
    }

    private var deviationText: String {
        guard let state = model.liveState else { return "—" }
        let deviation = state.deviation.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always()))
        let overlay = state.isVisible ? String(localized: "overlay on") : String(localized: "overlay off")
        return "\(deviation)° · \(overlay)"
    }

    private var stateText: String {
        if !model.isEnabled { return String(localized: "Disabled") }
        if !model.suspensions.isEmpty {
            let reasons = model.suspensions.map(\.description).sorted().formatted(.list(type: .and))
            return String(localized: "Suspended (\(reasons))")
        }
        if !model.hasBuiltInDisplay { return String(localized: "Built-in display inactive") }
        if model.isPaused { return String(localized: "Paused") }
        return model.power.description
    }
}
