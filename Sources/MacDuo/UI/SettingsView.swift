import MacDuoKit
import SwiftUI

/// Settings window: status, tuning of the active components, presets.
struct SettingsView: View {
    static let windowID = "settings"
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Status", systemImage: "gauge.with.dots.needle.33percent") {
                StatusPane(model: model)
            }
            Tab("Tuning", systemImage: "slider.horizontal.3") {
                TuningPane(model: model)
            }
            Tab("Presets", systemImage: "square.stack") {
                PresetsPane(model: model)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

// MARK: - Status

private struct StatusPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                LabeledContent("Pause shortcut", value: model.pauseShortcut)
                Picker("Language", selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    Text("Follow System").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                }
                if model.languageNeedsRelaunch {
                    HStack {
                        Text("The new language applies after a relaunch.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch") { model.relaunch() }
                    }
                }
                if let problem = model.hotKeyProblem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            Section("Live") {
                StatusSummary(model: model)
            }
            Section("Lid sensor") {
                LabeledContent("Status", value: model.sensorStatus.description)
            }
            Section("Screen Recording") {
                LabeledContent("Permission", value: model.hasCapturePermission
                               ? String(localized: "Granted") : String(localized: "Not granted"))
                if !model.hasCapturePermission {
                    Text("Mac Duo needs Screen Recording access to redraw the desktop from a live capture of the built-in display. Frames stay in memory and are never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Request access") { model.requestCapturePermission() }
                        Button("Open System Settings") { model.openScreenRecordingSettings() }
                        Button("Relaunch") { model.relaunch() }
                    }
                }
            }
            Section("Display") {
                LabeledContent("Built-in display", value: model.hasBuiltInDisplay
                               ? String(localized: "Active") : String(localized: "Inactive"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tuning

private struct TuningPane: View {
    let model: AppModel

    var body: some View {
        Form {
            if let motion = model.motionInfo {
                ComponentSection(model: model, info: motion)
            }
            if let effect = model.effectInfo {
                ComponentSection(model: model, info: effect)
            }
        }
        .formStyle(.grouped)
    }
}

/// Generated controls for one component's parameters.
private struct ComponentSection: View {
    let model: AppModel
    let info: ComponentInfo

    var body: some View {
        Section {
            ForEach(info.parameters) { spec in
                ParameterControl(
                    spec: spec,
                    value: Binding(
                        get: { model.parameters(for: info.id)[spec] },
                        set: { model.setParameter(spec, to: $0, component: info.id) }))
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                    Text(info.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset to defaults") { model.resetParameters(component: info.id) }
                    .controlSize(.small)
            }
        }
    }
}

/// One generated control for a parameter declaration.
struct ParameterControl: View {
    let spec: ParameterSpec
    @Binding var value: Double

    var body: some View {
        control
            .help(spec.detail ?? spec.name)
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .continuous(let range, let step):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(spec.name)
                    Spacer()
                    Text(formatted(value, step: step))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // Stepping happens in `ParameterValues`; a stepped Slider would draw tick marks.
                Slider(value: $value, in: range)
                if let detail = spec.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .choice(let options):
            Picker(spec.name, selection: Binding(get: { Int(value) }, set: { value = Double($0) })) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index]).tag(index)
                }
            }
        }
    }

    private func formatted(_ value: Double, step: Double) -> String {
        let digits: Int
        switch step {
        case 1...: digits = 0
        case 0.1...: digits = 1
        case 0.01...: digits = 2
        case 0.001...: digits = 3
        default: digits = step == 0 ? 3 : 4
        }
        let number = value.formatted(.number.precision(.fractionLength(digits)))
        return spec.unit.map { "\(number) \($0)" } ?? number
    }
}

// MARK: - Presets

private struct PresetsPane: View {
    let model: AppModel
    @State private var newName = ""
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        Form {
            Section("Built-in") {
                ForEach(model.builtInPresets) { preset in
                    PresetRow(preset: preset) {
                        Button("Apply") { model.apply(preset) }
                    }
                }
            }
            Section("Saved") {
                if model.userPresets.isEmpty {
                    Text("No saved presets yet.").foregroundStyle(.secondary)
                }
                ForEach(model.userPresets) { preset in
                    if renaming == preset.id {
                        HStack {
                            TextField("Name", text: $renameText)
                                .onSubmit { commitRename(preset.id) }
                            Button("Done") { commitRename(preset.id) }
                        }
                    } else {
                        PresetRow(preset: preset) {
                            Button("Apply") { model.apply(preset) }
                            Button("Update") { model.updatePreset(preset.id) }
                                .help("Replace with the current configuration")
                            Button("Rename") {
                                renameText = preset.name
                                renaming = preset.id
                            }
                            Button("Delete", role: .destructive) { model.deletePreset(preset.id) }
                        }
                    }
                }
            }
            Section("Save current configuration") {
                HStack {
                    TextField("Preset name", text: $newName)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        model.saveCurrentAsPreset(named: newName)
        newName = ""
    }

    private func commitRename(_ id: UUID) {
        model.renamePreset(id, to: renameText)
        renaming = nil
    }
}

private struct PresetRow<Actions: View>: View {
    let preset: Preset
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                Text(componentNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions()
                .controlSize(.small)
        }
    }

    @MainActor
    private var componentNames: String {
        let motion = ComponentRegistry.motionModel(id: preset.motionID)?.info.name ?? preset.motionID
        let effect = ComponentRegistry.effect(id: preset.effectID)?.info.name ?? preset.effectID
        return "\(motion) · \(effect)"
    }
}
