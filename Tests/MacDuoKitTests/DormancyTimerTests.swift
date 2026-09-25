import Foundation
import Testing
@testable import MacDuoKit

struct DormancyTimerTests {
    /// Runs 60 Hz frames for `duration`; returns the first time the timer fired.
    static func firstDormant(duration: TimeInterval, resolution: LidSample.Resolution = .fine,
                             angle: (TimeInterval) -> Double?, visible: (TimeInterval) -> Bool = { _ in false }) -> TimeInterval? {
        var timer = DormancyTimer()
        let count = Int((duration * 60).rounded())
        for index in 0...count {
            let t = Double(index) / 60
            let sample = angle(t).map { LidSample(angle: $0, timestamp: t, resolution: resolution) }
            if timer.update(sample: sample, isVisible: visible(t), at: t) { return t }
        }
        return nil
    }

    @Test func aHiddenStillLidGoesDormantAfterTheDelay() {
        let fired = Self.firstDormant(duration: 3) { _ in 120 }
        #expect(fired != nil)
        #expect(abs((fired ?? 0) - 1) < 1.0 / 60)
    }

    @Test func nothingIsReleasedWhileTheEffectIsVisible() {
        #expect(Self.firstDormant(duration: 10, angle: { _ in 60 }, visible: { _ in true }) == nil)
        // The idle period starts only once the effect is gone.
        let fired = Self.firstDormant(duration: 5, angle: { _ in 60 }, visible: { t in t < 2 })
        #expect(abs((fired ?? 0) - 3) < 1.0 / 60)
    }

    @Test func lidMovementKeepsTheEngineAwake() {
        // A slow close above the release angle (nothing visible yet) for 3 s, then a stop.
        let fired = Self.firstDormant(duration: 6) { t in 115 - 3 * min(t, 3) }
        #expect(fired != nil)
        #expect((fired ?? 0) >= 4 - 0.1)
    }

    @Test func sensorNoiseAndWholeDegreeDitherCountAsStill() {
        let noisy = Self.firstDormant(duration: 3) { t in 120 + 0.08 * sin(t * 40) }
        #expect(abs((noisy ?? 0) - 1) < 1.0 / 60)
        let dither = Self.firstDormant(duration: 3, resolution: .coarse) { t in Int(t * 10) % 2 == 0 ? 122 : 123 }
        #expect(abs((dither ?? 0) - 1) < 1.0 / 60)
    }

    @Test func aMissingSensorGoesDormantToo() {
        let fired = Self.firstDormant(duration: 3) { _ in nil }
        #expect(abs((fired ?? 0) - 1) < 1.0 / 60)
        // Losing the sensor restarts the idle period.
        let lost = Self.firstDormant(duration: 3) { t in t < 0.5 ? 120 : nil }
        #expect(abs((lost ?? 0) - 1.5) < 1.0 / 60)
    }

    @Test func resetRestartsTheIdlePeriod() {
        var timer = DormancyTimer()
        let sample = LidSample(angle: 120, timestamp: 0, resolution: .fine)
        _ = timer.update(sample: sample, isVisible: false, at: 0)
        timer.reset()
        let fired = timer.update(sample: sample, isVisible: false, at: 1.5)
        #expect(!fired)
        let later = timer.update(sample: sample, isVisible: false, at: 2.5)
        #expect(later)
    }
}
