import Foundation
import Testing
@testable import MacDuoKit

struct ArmingDetectorTests {
    /// The angles below assume a release angle of 100°, which puts the approach band at 100°–115°.
    static let configuration = ArmingDetector.Configuration(releaseAngle: 100)

    /// Feeds `angle(t)` sampled at `rate` Hz for `duration` seconds; returns the first time it armed.
    static func firstArm(rate: Double = 5, duration: TimeInterval, resolution: LidSample.Resolution = .fine,
                         angle: (TimeInterval) -> Double) -> TimeInterval? {
        var detector = ArmingDetector(configuration: Self.configuration)
        let count = Int((duration * rate).rounded())
        for index in 0...count {
            let t = Double(index) / rate
            let value = resolution == .coarse ? angle(t).rounded() : angle(t)
            if detector.ingest(LidSample(angle: value, timestamp: t, resolution: resolution)) { return t }
        }
        return nil
    }

    @Test func deskWobbleAndKnocksNeverArm() {
        // ±1.5° knocks at 2 Hz on a lid resting at 110° (inside the approach band), sampled at 5 and 10 Hz.
        #expect(Self.firstArm(duration: 10) { t in 110 + 1.5 * sin(2 * .pi * 2 * t) } == nil)
        #expect(Self.firstArm(rate: 10, duration: 10) { t in 110 + 1.5 * sin(2 * .pi * 2 * t) } == nil)
        // A single 2° knock that springs back.
        #expect(Self.firstArm(duration: 5) { t in t > 1 && t < 1.2 ? 108 : 110 } == nil)
        // Slow sway of a wobbling desk: 0.3° oscillation.
        #expect(Self.firstArm(rate: 10, duration: 10) { t in 105 + 0.3 * sin(t * 5) } == nil)
    }

    @Test func nothingWellAboveTheReleaseAngleArms() {
        // Opening wider, closing a little, knocking: all at or above 115°.
        #expect(Self.firstArm(duration: 3) { t in 115 + 20 * t } == nil)
        #expect(Self.firstArm(duration: 3) { t in 135 - 6 * t } == nil)
        #expect(Self.firstArm(duration: 5) { t in 125 + 4 * sin(2 * .pi * t) } == nil)
    }

    @Test func aBriskCloseArmsBeforeTheReleaseAngle() {
        // 100°/s from 118° with 5 Hz sampling: samples at 118, 98, …; arms on the first sample below 100
        // at the latest; with 10 Hz sampling it arms while still above 100.
        let slowPoll = Self.firstArm(rate: 5, duration: 1) { t in max(118 - 100 * t, 30) }
        #expect(slowPoll != nil)
        #expect(118 - 100 * (slowPoll ?? 0) >= 95)
        let fastPoll = Self.firstArm(rate: 10, duration: 1) { t in max(118 - 100 * t, 30) }
        #expect(118 - 100 * (fastPoll ?? 0) > 100)
    }

    @Test func aSlowCloseArmsWithinTheApproachBand() {
        // 10°/s from 114°: 2.5° of travel after 0.25 s, still well above 100°.
        let armed = Self.firstArm(rate: 5, duration: 3) { t in 114 - 10 * t }
        #expect(armed != nil)
        #expect(114 - 10 * (armed ?? 0) > 105)
    }

    @Test func aVerySlowDeliberateCloseStillArmsBeforeTheReleaseAngle() {
        // 1.5°/s from 104°: slower than any short window would notice, yet it arms after 2.5° of travel.
        let armed = Self.firstArm(rate: 5, duration: 4) { t in 104 - 1.5 * t }
        #expect(armed != nil)
        #expect(104 - 1.5 * (armed ?? 0) > 100)
    }

    @Test func aCreepSlowerThanTheRestToleranceNeverArms() {
        // 0.4°/s for 20 s: every 0.6 s the lid counts as resting again and the reference follows it.
        #expect(Self.firstArm(duration: 20) { t in 112 - 0.4 * t } == nil)
    }

    @Test func aCloseFromHighUpArmsOnceItEntersTheBand() {
        // From 130° at 60°/s: nothing until below 115°, then it arms immediately.
        let armed = Self.firstArm(rate: 10, duration: 1.5) { t in max(130 - 60 * t, 40) }
        #expect(armed != nil)
        let angle = 130 - 60 * (armed ?? 0)
        #expect(angle < 115 && angle > 100)
    }

    @Test func lowAngleUseIgnoresSmallAdjustmentsButArmsOnRealMovement() {
        // A lid used at 20°: ±2° adjustments and knocks do nothing.
        #expect(Self.firstArm(duration: 10) { t in 20 + 2 * sin(2 * .pi * 0.5 * t) } == nil)
        // Two 4° adjustments with a rest in between do not add up.
        #expect(Self.firstArm(duration: 6) { t in t < 1 ? 20 : (t < 3 ? 24 : 28) } == nil)
        // A deliberate 8° move does.
        #expect(Self.firstArm(duration: 3) { t in t < 1 ? 20 : min(20 + 20 * (t - 1), 28) } != nil)
        // Opening from a low angle towards normal use arms too.
        #expect(Self.firstArm(duration: 3) { t in t < 1 ? 60 : 60 + 40 * (t - 1) } != nil)
    }

    @Test func restsBetweenSmallStepsResetTheReference() {
        // 1° every 0.8 s in the approach band: each step settles before the next one.
        #expect(Self.firstArm(rate: 10, duration: 8) { t in 112 - Double(Int(t / 0.8)) } == nil)
    }

    @Test func wholeDegreeDitherNeverArmsButAWholeDegreeCloseDoes() {
        #expect(Self.firstArm(rate: 10, duration: 10, resolution: .coarse) { t in 101.5 + 0.6 * sin(2 * .pi * 3 * t) } == nil)
        #expect(Self.firstArm(rate: 10, duration: 10, resolution: .coarse) { t in 20.5 + 0.6 * sin(2 * .pi * 3 * t) } == nil)
        let armed = Self.firstArm(rate: 10, duration: 3, resolution: .coarse) { t in 110 - 4 * t }
        #expect(armed != nil)
        #expect(110 - 4 * (armed ?? 0) > 100)
    }

    @Test func outOfOrderSamplesAreIgnored() {
        var detector = ArmingDetector(configuration: Self.configuration)
        _ = detector.ingest(LidSample(angle: 112, timestamp: 1, resolution: .fine))
        let armed = detector.ingest(LidSample(angle: 90, timestamp: 0.5, resolution: .fine))
        #expect(!armed)
    }

    @Test func resetForgetsHistory() {
        var detector = ArmingDetector(configuration: Self.configuration)
        _ = detector.ingest(LidSample(angle: 112, timestamp: 0, resolution: .fine))
        detector.reset()
        let armed = detector.ingest(LidSample(angle: 108, timestamp: 0.2, resolution: .fine))
        #expect(!armed)
    }
}
