import Foundation
import Testing
@testable import MacDuoKit

struct PresetTests {
    @Test func applyingPresetKeepsOtherComponentsTuning() {
        var selection = Selection(motionID: "m1", effectID: "e1")
        selection.setParameters(ParameterValues(["a": 1]), for: "e1")
        selection.setParameters(ParameterValues(["b": 2]), for: "e2")

        selection.apply(Preset(name: "P", motionID: "m2", effectID: "e2",
                               motionParameters: ParameterValues(["c": 3]), effectParameters: ParameterValues(["b": 5])))

        #expect(selection.motionID == "m2")
        #expect(selection.effectID == "e2")
        #expect(selection.effectParameters == ParameterValues(["b": 5]))
        #expect(selection.parameters(for: "e1") == ParameterValues(["a": 1]))
    }

    @Test func snapshotCapturesLiveConfiguration() {
        var selection = Selection(motionID: "m", effectID: "e")
        selection.setParameters(ParameterValues(["x": 4]), for: "m")
        let preset = selection.snapshot(named: "Mine")
        #expect(preset.name == "Mine")
        #expect(preset.motionParameters == ParameterValues(["x": 4]))
        #expect(preset.effectParameters == ParameterValues())
    }

    @Test func pruneDropsRemovedComponentsAndParameters() {
        let kept = ParameterSpec(id: "kept", name: "Kept", range: 0...10, default: 1)
        var selection = Selection(motionID: "m", effectID: "e")
        selection.setParameters(ParameterValues(["kept": 4, "removed": 2]), for: "m")
        selection.setParameters(ParameterValues(["x": 1]), for: "deleted-component")
        selection.setParameters(ParameterValues(), for: "e")

        selection.prune(keeping: ["m": [kept], "e": []])

        #expect(selection.parametersByComponent == ["m": ParameterValues(["kept": 4]), "e": ParameterValues()])
    }

    @Test func roundTripsThroughJSON() throws {
        var selection = Selection(motionID: "m", effectID: "e")
        selection.setParameters(ParameterValues(["x": 4]), for: "m")
        let data = try JSONEncoder().encode(selection)
        #expect(try JSONDecoder().decode(Selection.self, from: data) == selection)

        let preset = selection.snapshot(named: "P")
        let presetData = try JSONEncoder().encode([preset])
        #expect(try JSONDecoder().decode([Preset].self, from: presetData) == [preset])
    }
}
