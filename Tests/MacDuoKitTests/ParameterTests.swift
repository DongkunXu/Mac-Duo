import Foundation
import Testing
@testable import MacDuoKit

struct ParameterTests {
    let blur = ParameterSpec(id: "blur", name: "Blur", range: 0...100, step: 5, default: 40, unit: "px")
    let smooth = ParameterSpec(id: "smooth", name: "Smooth", range: 0...1, default: 0.5)
    let mode = ParameterSpec.choice(id: "mode", name: "Mode", options: ["A", "B", "C"], default: 1)

    @Test func missingValuesReadAsDefaults() {
        let values = ParameterValues()
        #expect(values[blur] == 40)
        #expect(values.index(mode) == 1)
    }

    @Test func continuousValuesAreClampedAndStepped() {
        var values = ParameterValues()
        values[blur] = 123
        #expect(values[blur] == 100)
        values[blur] = -4
        #expect(values[blur] == 0)
        values[blur] = 42.4
        #expect(values[blur] == 40)
        values[blur] = 43
        #expect(values[blur] == 45)
        values[smooth] = 0.333
        #expect(values[smooth] == 0.333)
    }

    @Test func nonFiniteValuesFallBackToDefault() {
        #expect(blur.sanitize(.nan) == 40)
        #expect(blur.sanitize(.infinity) == 40)
    }

    @Test func choicesAreSanitized() {
        var values = ParameterValues()
        values[mode] = 7
        #expect(values.index(mode) == 2)
        values[mode] = -3
        #expect(values.index(mode) == 0)
    }

    @Test func storedOutOfDomainValuesAreSanitizedOnRead() throws {
        let decoded = try JSONDecoder().decode(ParameterValues.self, from: Data(#"{"blur": 999, "mode": 1.6}"#.utf8))
        #expect(decoded[blur] == 100)
        #expect(decoded.index(mode) == 2)
    }

    @Test func roundTripsThroughJSON() throws {
        var values = ParameterValues()
        values[blur] = 55
        values[mode] = 2
        let data = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode(ParameterValues.self, from: data) == values)
    }

    @Test func restrictionDropsForeignKeys() {
        let values = ParameterValues(["blur": 10, "unrelated": 3])
        let restricted = values.restricted(to: [blur, mode])
        #expect(restricted == ParameterValues(["blur": 10]))
    }
}
