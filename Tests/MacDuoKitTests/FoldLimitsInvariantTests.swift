import Foundation
import Testing
@testable import MacDuoKit

/// Global rule: nothing is shown while the lid is at or above the release angle a model is tuned
/// to. The render host leaves violations visible, and every model is checked here: at its defaults, every
/// choice combination and both ends of the adjustable release range, at fine and whole-degree
/// resolution, through realistic lid movements (`MotionSimulator`). A frame is a violation when
/// - the true lid is ≥ release + 0.5° and the model's own lid angle is ≥ release, or
/// - the true lid has been at or above the release angle for 0.5 s.
struct FoldLimitsInvariantTests {
    /// The per-frame check applies once the true lid is this far above the release angle.
    static let margin = 0.5
    /// A lid that has stayed at or above the release angle this long must never be shown.
    static let restLimit: TimeInterval = 0.5

    // MARK: Scenarios

    enum Segment: Sendable {
        /// The lid held at an angle for a duration.
        case hold(Double, TimeInterval)
        /// Linear movement from one angle to another over a duration.
        case sweep(Double, Double, TimeInterval)
        /// `center + amplitude · cos(2π t / period)` for a duration; starts at `center + amplitude`
        /// and ends there after a whole number of periods.
        case wave(center: Double, amplitude: Double, period: TimeInterval, duration: TimeInterval)
        /// A resting lid with ±0.05° of sensor noise, enough to flip whole-degree readings on a
        /// rounding boundary.
        case dither(Double, TimeInterval)
        /// No sensor data (system sleep).
        case gap(TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .hold(_, let duration), .sweep(_, _, let duration), .dither(_, let duration), .gap(let duration):
                duration
            case .wave(_, _, _, let duration):
                duration
            }
        }

        /// True lid angle at `fraction` (0...1) of the segment, `elapsed` seconds into it.
        func angle(fraction: Double, elapsed: TimeInterval) -> Double {
            switch self {
            case .hold(let angle, _):
                angle
            case .sweep(let start, let end, _):
                start + (end - start) * fraction
            case .wave(let center, let amplitude, let period, _):
                center + amplitude * cos(2 * .pi * elapsed / period)
            case .dither(let center, _):
                center + 0.05 * sin(elapsed * 83)
            case .gap:
                .nan
            }
        }
    }

    struct Scenario: Sendable {
        var name: String
        var segments: [Segment]
        /// The lid closes well below the release angle, and every model's default configuration must
        /// show the effect at some point. This guards against a check that passes vacuously.
        var showsBelowRelease = false
    }

    static let scenarios: [Scenario] = [
        Scenario(name: "rest at 110°", segments: [.hold(110, 6)]),
        Scenario(name: "rest at 120°", segments: [.hold(120, 6)]),
        Scenario(name: "rest at 130°", segments: [.hold(130, 6)]),
        Scenario(name: "rest at 122.5° with sensor noise", segments: [.dither(122.5, 6)]),
        Scenario(name: "brisk close 125° → 30° and back",
                 segments: [.hold(125, 2), .sweep(125, 30, 0.6), .hold(30, 0.5), .sweep(30, 125, 0.6), .hold(125, 2)],
                 showsBelowRelease: true),
        Scenario(name: "slow close 125° → 30° and back",
                 segments: [.hold(125, 2), .sweep(125, 30, 5), .hold(30, 1), .sweep(30, 125, 5), .hold(125, 3)],
                 showsBelowRelease: true),
        Scenario(name: "brisk close stopping at 96°, then rest",
                 segments: [.hold(125, 2), .sweep(125, 96, 0.3), .hold(96, 4)]),
        Scenario(name: "slow close stopping at 96°, then rest",
                 segments: [.hold(125, 2), .sweep(125, 96, 3), .hold(96, 4)]),
        Scenario(name: "brisk opening from 5° after sleep to 120°",
                 segments: [.hold(125, 2), .sweep(125, 5, 1), .hold(5, 0.5), .gap(3600),
                            .hold(5, 0.2), .sweep(5, 120, 1), .hold(120, 3)]),
        Scenario(name: "slow opening from 5° after sleep to 120°",
                 segments: [.hold(125, 2), .sweep(125, 5, 1), .hold(5, 0.5), .gap(3600),
                            .hold(5, 0.2), .sweep(5, 120, 4), .hold(120, 3)]),
        Scenario(name: "oscillation 90°–114°, 1 s period",
                 segments: [.hold(114, 2), .wave(center: 102, amplitude: 12, period: 1, duration: 8), .hold(114, 2)],
                 showsBelowRelease: true),
        Scenario(name: "oscillation 90°–114°, 4 s period",
                 segments: [.hold(114, 2), .wave(center: 102, amplitude: 12, period: 4, duration: 12), .hold(114, 2)],
                 showsBelowRelease: true),
        Scenario(name: "nudges around 105°",
                 segments: [.hold(105, 2),
                            .sweep(105, 103, 0.15), .hold(103, 0.8),
                            .sweep(103, 107, 0.2), .hold(107, 0.8),
                            .sweep(107, 104, 0.15), .hold(104, 0.8),
                            .sweep(104, 101.5, 0.2), .hold(101.5, 0.8),
                            .sweep(101.5, 106, 0.3), .hold(106, 0.8),
                            .sweep(106, 105, 0.1), .hold(105, 2)]),
    ]

    // MARK: Parameter variants

    struct Variant {
        var label: String
        var parameters: ParameterValues
        var isDefault: Bool
    }

    /// The defaults, plus every combination of the model's choice parameters.
    static func variants(of info: ComponentInfo) -> [Variant] {
        var combinations: [[(spec: ParameterSpec, value: Double)]] = [[]]
        for spec in info.parameters {
            let values: [Double]
            switch spec.kind {
            case .continuous:
                continue
            case .choice(let options):
                values = options.indices.map(Double.init)
            }
            combinations = combinations.flatMap { combination in values.map { combination + [(spec, $0)] } }
        }
        return combinations.map { combination in
            var parameters = ParameterValues()
            for (spec, value) in combination { parameters[spec] = value }
            let changed = combination.filter { $0.value != $0.spec.defaultValue }
            let label = changed.isEmpty
                ? "defaults"
                : changed.map { "\($0.spec.id)=\(Int($0.value))" }.joined(separator: ", ")
            return Variant(label: label, parameters: parameters, isDefault: changed.isEmpty)
        }
    }

    // MARK: Driving and checking

    struct Frame {
        /// Seconds since the scenario started.
        var time: TimeInterval
        /// The true lid angle this frame, nil during a sensor gap.
        var truth: Double?
        var state: FoldState
    }

    static func run<Model: MotionModel>(_: Model.Type, parameters: ParameterValues,
                                        resolution: LidSample.Resolution, scenario: Scenario) -> [Frame] {
        var sim = MotionSimulator<Model>(parameters: parameters)
        sim.resolution = resolution
        let start = sim.time
        var frames: [Frame] = []
        for segment in scenario.segments {
            if case .gap(let duration) = segment {
                sim.gap(duration)
                frames.append(Frame(time: sim.time - start, truth: nil, state: sim.last))
                continue
            }
            // One simulator frame at a time, which makes the true angle of every frame known. The simulator
            // still decides when the sensor value updates (10 Hz) and rounds whole-degree data.
            let count = max(Int((segment.duration * sim.frameRate).rounded()), 1)
            for index in 1...count {
                let truth = segment.angle(fraction: Double(index) / Double(count),
                                          elapsed: Double(index) / sim.frameRate)
                sim.run(for: 1 / sim.frameRate) { _ in truth }
                frames.append(Frame(time: sim.time - start, truth: truth, state: sim.last))
            }
        }
        return frames
    }

    struct Violation: CustomStringConvertible {
        var frame: Frame
        var rule: String

        var description: String {
            let state = frame.state
            return "t = \(Self.format(frame.time, 3)) s, true lid \(Self.format(frame.truth ?? .nan, 2))°, "
                + "model lid \(Self.format(state.lidAngle, 2))°, reference \(Self.format(state.referenceAngle, 2))°, "
                + "deviation \(Self.format(state.deviation, 3))°: \(rule)"
        }

        static func format(_ value: Double, _ digits: Int) -> String {
            String(format: "%.\(digits)f", value)
        }
    }

    static func violations(in frames: [Frame], release: Double) -> [Violation] {
        var aboveSince: TimeInterval?
        var found: [Violation] = []
        for frame in frames {
            guard let truth = frame.truth else {
                // After a gap the lid's history is unknown; a new rest starts with the next reading.
                aboveSince = nil
                continue
            }
            if truth >= release {
                aboveSince = aboveSince ?? frame.time
            } else {
                aboveSince = nil
            }
            guard frame.state.isVisible else { continue }
            if truth >= release + margin, frame.state.lidAngle >= release {
                found.append(Violation(frame: frame, rule: "visible with the true lid ≥ \(Violation.format(release + margin, 1))°"
                                       + " and the model's lid ≥ \(Violation.format(release, 0))°"))
            } else if let since = aboveSince, frame.time - since >= restLimit {
                found.append(Violation(frame: frame, rule: "visible after the true lid stayed ≥ \(Violation.format(release, 0))° for "
                                       + "\(Violation.format(frame.time - since, 3)) s"))
            }
        }
        return found
    }

    /// Every choice combination, plus the default tuning at both ends of the release range when the
    /// user can move the release angle.
    static func allVariants<Model: MotionModel>(_: Model.Type) -> [Variant] {
        var all = variants(of: Model.info)
        guard let spec = Model.releaseAngleParameter, let base = all.first(where: \.isDefault),
              case .continuous(let range, _) = spec.kind else { return all }
        for angle in [range.lowerBound + 20, range.upperBound] {
            var parameters = base.parameters
            parameters[spec] = angle
            all.append(Variant(label: "\(spec.id)=\(Violation.format(angle, 0))", parameters: parameters, isDefault: false))
        }
        return all
    }

    static func check<Model: MotionModel>(_: Model.Type) {
        let id = Model.info.id
        for variant in allVariants(Model.self) {
            let release = Model.releaseAngle(for: variant.parameters)
            for resolution in [LidSample.Resolution.fine, .coarse] {
                for scenario in scenarios {
                    let frames = run(Model.self, parameters: variant.parameters, resolution: resolution, scenario: scenario)
                    let context = "\(id) [\(variant.label), \(resolution)] \"\(scenario.name)\""
                    if variant.isDefault, scenario.showsBelowRelease {
                        #expect(frames.contains { $0.state.isVisible },
                                "\(context): the effect never showed and the scenario did not exercise the model")
                    }
                    let found = violations(in: frames, release: release)
                    guard let first = found.first, let last = found.last else { continue }
                    Issue.record("""
                        \(context): \(found.count) frame(s) visible at or above the release angle, \
                        from t = \(Violation.format(first.frame.time, 3)) s to \(Violation.format(last.frame.time, 3)) s. \
                        First: \(first). Last: \(last).
                        """)
                }
            }
        }
    }

    // MARK: Tests

    /// Every motion model must be checked here; add new models to this test.
    @Test func opticalReferenceShowsNothingAtOrAboveTheReleaseAngle() {
        Self.check(OpticalReferenceMotion.self)
    }

    @Test func variantsCoverEveryChoiceValue() {
        let info = ComponentInfo(id: "variants-fixture", name: "Fixture", summary: "", parameters: [
            .choice(id: "a", name: "A", options: ["x", "y"], default: 1),
            .choice(id: "b", name: "B", options: ["x", "y", "z"], default: 0),
            ParameterSpec(id: "c", name: "C", range: 0...1, default: 0.5),
        ])
        // Two × three choices; continuous parameters stay at their defaults.
        let variants = Self.variants(of: info)
        #expect(variants.count == 6)
        #expect(variants.filter(\.isDefault).count == 1)
        #expect(Set(variants.map(\.label)).count == 6)
        // A model without choices runs once, with its defaults.
        #expect(Self.variants(of: OpticalReferenceMotion.info).map(\.label) == ["defaults"])
    }

    @Test func checkerFlagsVisibleFramesAboveTheReleaseAngle() {
        let release = 95.0
        func frame(_ time: TimeInterval, truth: Double, lid: Double, visible: Bool) -> Frame {
            Frame(time: time, truth: truth,
                  state: FoldState(lidAngle: lid, referenceAngle: release, isVisible: visible))
        }
        // Past the margin but with a lagging model lid below the release angle: allowed.
        #expect(Self.violations(in: [frame(0, truth: release + 4, lid: release - 1, visible: true)], release: release).isEmpty)
        // Visible with both at or above: flagged.
        #expect(Self.violations(in: [frame(0, truth: release + 4, lid: release, visible: true)], release: release).count == 1)
        // Just above the release angle (inside the margin) for 0.5 s: flagged once the rest limit is reached.
        let rest = (0...60).map { frame(Double($0) / 120, truth: release + 0.2, lid: release - 1, visible: true) }
        #expect(Self.violations(in: rest, release: release).count == 1)
        // A dip below the release angle restarts the rest.
        let dip = rest.enumerated().map { $0.offset == 30 ? frame($0.element.time, truth: release - 1, lid: release - 1, visible: true) : $0.element }
        #expect(Self.violations(in: dip, release: release).isEmpty)
    }
}
