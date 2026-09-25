import Foundation
import Testing
@testable import MacDuoKit

struct DeadBandTests {
    @Test func firstValuePassesThrough() {
        var band = DeadBand()
        #expect(band.apply(10, band: 0.5) == 10)
    }

    @Test func holdsInsideBandAndFollowsOutsideIt() {
        var band = DeadBand()
        _ = band.apply(10, band: 0.5)
        #expect(band.apply(10.3, band: 0.5) == 10)
        #expect(band.apply(9.8, band: 0.5) == 10)
        #expect(band.apply(11, band: 0.5) == 10.5)
        #expect(band.apply(9, band: 0.5) == 9.5)
    }

    @Test func trackedValueNeverStraysMoreThanTheBand() {
        var band = DeadBand()
        for step in 0..<500 {
            let raw = 100 + 20 * sin(Double(step) * 0.05) + (step.isMultiple(of: 2) ? 0.3 : -0.3)
            let tracked = band.apply(raw, band: 0.6)
            #expect(abs(tracked - raw) <= 0.6 + 1e-12)
        }
    }

    @Test func zeroBandIsTransparent() {
        var band = DeadBand()
        _ = band.apply(5, band: 0)
        #expect(band.apply(5.01, band: 0) == 5.01)
    }

    @Test func resetForgetsTheTrackedValue() {
        var band = DeadBand()
        _ = band.apply(10, band: 1)
        band.reset()
        #expect(band.apply(50, band: 1) == 50)
    }
}

struct AngleTrackerTests {
    @Test func firstValueHasNoVelocity() {
        var tracker = AngleTracker()
        tracker.ingest(angle: 100, at: 0)
        #expect(tracker.angle == 100)
        #expect(tracker.velocity(at: 0) == 0)
    }

    @Test func velocityIsMeasuredBetweenValueChanges() {
        var tracker = AngleTracker(velocityTimeConstant: 0.06, maxChangeInterval: 0.15)
        tracker.ingest(angle: 100, at: 0)
        tracker.ingest(angle: 99, at: 0.1)
        let alpha = 1 - exp(-0.1 / 0.06)
        #expect(abs(tracker.velocity(at: 0.1) - (-10 * alpha)) < 1e-9)
    }

    @Test func duplicateReadsDoNotCreateSpikes() {
        var withDuplicates = AngleTracker()
        var withoutDuplicates = AngleTracker()
        for index in 0...10 {
            let time = Double(index) * 0.1
            let angle = 120 - 10 * time
            withoutDuplicates.ingest(angle: angle, at: time)
            withDuplicates.ingest(angle: angle, at: time)
            // The same value polled eleven more times before the next change.
            for poll in 1...11 { withDuplicates.ingest(angle: angle, at: time + Double(poll) / 120) }
        }
        #expect(withDuplicates.velocity(at: 1) == withoutDuplicates.velocity(at: 1))
    }

    @Test func steadyMotionConvergesToTrueSpeed() {
        var tracker = AngleTracker()
        for index in 0...20 {
            let time = Double(index) * 0.1
            tracker.ingest(angle: 120 - 30 * time, at: time)
        }
        #expect(abs(tracker.velocity(at: 2) + 30) < 0.3)
    }

    @Test func velocityDecaysOnceChangesStop() {
        var tracker = AngleTracker(velocityTimeConstant: 0.06, maxChangeInterval: 0.15)
        for index in 0...10 { tracker.ingest(angle: 100 - Double(index), at: Double(index) * 0.1) }
        let moving = tracker.velocity(at: 1.0)
        let decayed = tracker.velocity(at: 1.0 + 0.15 + 0.06)
        #expect(abs(decayed - moving * exp(-1)) < 1e-9)
        #expect(abs(tracker.velocity(at: 3)) < 1e-6)
    }
}

struct StillnessDetectorTests {
    @Test func firstSampleIsNotMovement() {
        var stillness = StillnessDetector()
        stillness.ingest(angle: 100, at: 10, tolerance: 0.3)
        #expect(stillness.stillDuration(at: 11) == 1)
        #expect(!stillness.movedRecently(at: 10.1, within: 1))
    }

    @Test func changesInsideToleranceKeepTheAnchor() {
        var stillness = StillnessDetector()
        stillness.ingest(angle: 100, at: 10, tolerance: 0.3)
        stillness.ingest(angle: 100.25, at: 10.5, tolerance: 0.3)
        stillness.ingest(angle: 99.8, at: 11, tolerance: 0.3)
        #expect(stillness.anchor == 100)
        #expect(stillness.stillDuration(at: 12) == 2)
    }

    @Test func leavingToleranceIsMovement() {
        var stillness = StillnessDetector()
        stillness.ingest(angle: 100, at: 10, tolerance: 0.3)
        stillness.ingest(angle: 100.5, at: 11, tolerance: 0.3)
        #expect(stillness.anchor == 100.5)
        #expect(stillness.stillDuration(at: 11.2) == 0.2 || abs(stillness.stillDuration(at: 11.2) - 0.2) < 1e-9)
        #expect(stillness.movedRecently(at: 11.4, within: 0.5))
        #expect(!stillness.movedRecently(at: 11.6, within: 0.5))
    }

    @Test func resetClearsEverything() {
        var stillness = StillnessDetector()
        stillness.ingest(angle: 100, at: 10, tolerance: 0.3)
        stillness.ingest(angle: 101, at: 11, tolerance: 0.3)
        stillness.reset()
        #expect(stillness.anchor == nil)
        #expect(stillness.stillDuration(at: 20) == 0)
        #expect(!stillness.movedRecently(at: 11.1, within: 5))
    }
}

struct FoldStateTests {
    @Test func deviationIsGlassMinusReference() {
        let state = FoldState(lidAngle: 80, referenceAngle: 110, isVisible: true)
        #expect(state.deviation == -30)
    }

    @Test func hiddenStateIsAtRest() {
        let state = FoldState.hidden(at: 42)
        #expect(!state.isVisible)
        #expect(state.deviation == 0)
    }
}
