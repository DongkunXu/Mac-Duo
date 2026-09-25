import Foundation
import Testing
@testable import MacDuoKit

struct SampleInterpolatorTests {
    @Test func emptyHasNoValue() {
        #expect(SampleInterpolator().value(at: 1, delay: 0.1) == nil)
    }

    @Test func interpolatesLinearlyBetweenChanges() {
        var interpolator = SampleInterpolator()
        interpolator.ingest(angle: 100, at: 10.0)
        interpolator.ingest(angle: 90, at: 10.1)
        interpolator.ingest(angle: 80, at: 10.2)
        #expect(abs(interpolator.value(at: 10.25, delay: 0.1)! - 85) < 1e-9)
        #expect(abs(interpolator.value(at: 10.3, delay: 0.1)! - 80) < 1e-9)
    }

    @Test func holdsTheLastValueAndNeverOvershoots() {
        var interpolator = SampleInterpolator()
        for step in 0...5 { interpolator.ingest(angle: 120 - 10 * Double(step), at: 10 + 0.1 * Double(step)) }
        for offset in stride(from: 0.0, through: 1.0, by: 0.01) {
            let value = interpolator.value(at: 10.5 + offset, delay: 0.1)!
            #expect(value >= 70 - 1e-9)
        }
        #expect(interpolator.value(at: 12, delay: 0.1) == 70)
    }

    @Test func repeatedPollsAreIgnored() {
        var withPolls = SampleInterpolator()
        var withoutPolls = SampleInterpolator()
        for step in 0...5 {
            let time = 10 + 0.1 * Double(step)
            let angle = 120 - 10 * Double(step)
            withPolls.ingest(angle: angle, at: time)
            withoutPolls.ingest(angle: angle, at: time)
            for poll in 1...11 { withPolls.ingest(angle: angle, at: time + Double(poll) / 120) }
        }
        for offset in stride(from: 0.0, through: 0.6, by: 0.013) {
            #expect(withPolls.value(at: 10.1 + offset, delay: 0.1) == withoutPolls.value(at: 10.1 + offset, delay: 0.1))
        }
    }

    @Test func motionAfterARestStartsWithinOneInterval() {
        var interpolator = SampleInterpolator(typicalInterval: 0.1, restGap: 0.25)
        interpolator.ingest(angle: 110, at: 5)
        interpolator.ingest(angle: 100, at: 10)
        // Without the rest handling the 10° would be spread over 5 s (≈ 100.3° at 9.85 s).
        #expect(interpolator.value(at: 9.85, delay: 0) == 110)
        #expect(abs(interpolator.value(at: 9.95, delay: 0)! - 105) < 1e-9)
        #expect(abs(interpolator.value(at: 10.05, delay: 0.1)! - 105) < 1e-9)
        #expect(interpolator.value(at: 10.1, delay: 0.1) == 100)
    }

    @Test func zeroDelayFollowsTheLatestValue() {
        var interpolator = SampleInterpolator()
        interpolator.ingest(angle: 100, at: 10.0)
        interpolator.ingest(angle: 90, at: 10.1)
        #expect(interpolator.value(at: 10.1, delay: 0) == 90)
    }

    @Test func resetForgetsHistory() {
        var interpolator = SampleInterpolator()
        interpolator.ingest(angle: 100, at: 10)
        interpolator.reset()
        #expect(interpolator.value(at: 10, delay: 0) == nil)
    }
}
