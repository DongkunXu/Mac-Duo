import Foundation
import Testing
@testable import MacDuoKit

struct OpticalReferenceMotionTests {
    typealias Model = OpticalReferenceMotion

    /// The angle the model releases at with its default tuning; the user can lower it.
    static let release = ParameterValues()[Model.releaseAngle]

    static func parameters(_ pairs: [(ParameterSpec, Double)]) -> ParameterValues {
        var values = ParameterValues()
        for (spec, value) in pairs { values[spec] = value }
        return values
    }

    @Test func releaseAngleDefaultsBelowAndIsCappedAtTheGlobalLimit() {
        #expect(Self.release == 95)
        // The hard ceiling no model may cross, whatever the user sets.
        #expect(FoldLimits.releaseAngle == 120)
        #expect(Self.release <= FoldLimits.releaseAngle)
        var values = ParameterValues()
        values[Model.releaseAngle] = 130
        #expect(values[Model.releaseAngle] == FoldLimits.releaseAngle)
    }

    @Test func nothingHappensAtOrAboveTheReleaseAngle() {
        var sim = MotionSimulator<Model>()
        sim.hold(110, for: 1)
        sim.sweep(from: 110, to: 130, over: 0.5)
        sim.hold(130, for: 0.5)
        sim.sweep(from: 130, to: 101, over: 0.7)
        sim.hold(101, for: 0.5)
        sim.hold(100, for: 0.5)
        sim.hold(120, for: 0.5)
        #expect(sim.states.allSatisfy { !$0.isVisible && $0.deviation == 0 })
    }

    @Test func closingBelowTheReleaseAngleTiltsFromIt() {
        var sim = MotionSimulator<Model>()
        sim.hold(115, for: 1)
        sim.sweep(from: 115, to: 60, over: 1)
        sim.hold(60, for: 0.3)
        #expect(sim.last.isVisible)
        #expect(abs(sim.last.referenceAngle - Self.release) < 1e-9)
        #expect(abs(sim.last.deviation - (sim.last.lidAngle - Self.release)) < 1e-9)
        #expect(abs(sim.last.lidAngle - 60) < 0.2)
    }

    @Test func closingSteadilyGrowsTheDeviationMonotonically() {
        var sim = MotionSimulator<Model>()
        sim.hold(120, for: 1)
        sim.sweep(from: 120, to: 40, over: 1)
        let magnitudes = sim.states.map { abs($0.deviation) }
        #expect(zip(magnitudes.dropFirst(), magnitudes).allSatisfy { $0 >= $1 - 1e-9 })
        #expect(sim.last.isVisible)
    }

    @Test func reopeningReleasesContinuouslyAtTheReleaseAngle() {
        var sim = MotionSimulator<Model>()
        sim.hold(40, for: 0.5)
        sim.sweep(from: 40, to: 120, over: 1.2)
        sim.hold(120, for: 0.5)
        #expect(!sim.last.isVisible)
        #expect(sim.last.deviation == 0)
        let magnitudes = sim.states.map { abs($0.deviation) }
        let steps = zip(magnitudes.dropFirst(), magnitudes).map { abs($0 - $1) }
        #expect(steps.max()! < 2)
    }

    @Test func releaseAngleCanBeLowered() {
        var sim = MotionSimulator<Model>(parameters: Self.parameters([(Model.releaseAngle, 90)]))
        sim.hold(110, for: 1)
        sim.sweep(from: 110, to: 95, over: 0.3)
        sim.hold(95, for: 0.3)
        #expect(!sim.last.isVisible)
        sim.sweep(from: 95, to: 80, over: 0.3)
        sim.hold(80, for: 0.3)
        #expect(sim.last.isVisible)
        #expect(abs(sim.last.deviation + 10) < 0.2)
    }

    @Test func holdingStillBelowClearsAndMovingBringsItBack() {
        var sim = MotionSimulator<Model>()
        sim.hold(110, for: 1)
        sim.sweep(from: 110, to: 70, over: 0.6)
        sim.hold(70, for: 4)
        #expect(!sim.last.isVisible)
        sim.sweep(from: 70, to: 60, over: 0.5)
        sim.hold(60, for: 0.4)
        #expect(sim.last.isVisible)
        #expect(abs(sim.last.deviation - (60 - Self.release)) < 0.5)
    }

    @Test func restingAboveTheReleaseAngleNeverWeakensTheNextClose() {
        var sim = MotionSimulator<Model>()
        sim.hold(110, for: 5)
        sim.sweep(from: 110, to: 70, over: 0.4)
        sim.hold(70, for: 0.3)
        #expect(sim.last.isVisible)
        #expect(abs(sim.last.deviation - (70 - Self.release)) < 0.5)
    }

    @Test func stoppingJustAboveTheReleaseAngleNeverFlashes() {
        // A brisk close that stops one degree above the release angle: interpolation never runs
        // past the measured angle.
        let stop = Self.release + 1
        var sim = MotionSimulator<Model>()
        sim.hold(125, for: 1)
        sim.sweep(from: 125, to: stop, over: 0.3)
        sim.hold(stop, for: 1)
        #expect(sim.states.allSatisfy { !$0.isVisible })
    }

    @Test func reopeningAfterSleepReleasesAtTheReleaseAngle() {
        var sim = MotionSimulator<Model>()
        sim.hold(110, for: 1)
        sim.sweep(from: 110, to: 2, over: 1)
        sim.gap(3600)
        #expect(!sim.last.isVisible)
        sim.sweep(from: 5, to: 115, over: 1.2)
        sim.hold(115, for: 0.5)
        #expect(!sim.last.isVisible)
        let midway = sim.states[sim.states.count - 60 - 72]
        #expect(midway.isVisible)
        #expect(midway.deviation < -20)
    }

    @Test func staleSamplesHideTheOverlay() {
        var model = Model()
        let params = ParameterValues()
        _ = model.update(sample: LidSample(angle: 120, timestamp: 10, resolution: .fine), at: 10, parameters: params)
        _ = model.update(sample: LidSample(angle: 60, timestamp: 10.1, resolution: .fine), at: 10.1, parameters: params)
        let stale = model.update(sample: LidSample(angle: 60, timestamp: 10.1, resolution: .fine), at: 11, parameters: params)
        #expect(!stale.isVisible)
    }

    @Test func coarseDitherAtRestStaysHidden() {
        for angle in [122.5, 80.5] {
            var sim = MotionSimulator<Model>()
            sim.resolution = .coarse
            // True angle sits on the rounding boundary and the whole-degree value flips.
            sim.hold(angle, for: 1)
            let before = sim.states.count
            sim.run(for: 5) { t in angle + 0.05 * sin(t * 400) }
            if angle > Self.release {
                #expect(sim.states.allSatisfy { !$0.isVisible })
            } else {
                // Below the release angle the dither must not count as motion: the hold clear still happens.
                #expect(!sim.last.isVisible)
                #expect(sim.states.count > before)
            }
        }
    }
}
