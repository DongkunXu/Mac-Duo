import Testing
@testable import MacDuoKit

struct SpringTests {
    private func advance(_ spring: inout CriticallyDampedSpring, toward target: Double, seconds: Double, hz: Double) {
        let steps = Int((seconds * hz).rounded())
        for _ in 0..<steps { spring.step(toward: target, dt: 1 / hz) }
    }

    @Test func resultIsIndependentOfFrameRate() {
        var at60 = CriticallyDampedSpring(position: 0, response: 0.1)
        var at120 = CriticallyDampedSpring(position: 0, response: 0.1)
        advance(&at60, toward: 90, seconds: 0.05, hz: 60)
        advance(&at120, toward: 90, seconds: 0.05, hz: 120)
        #expect(abs(at60.position - at120.position) < 1e-9)
        #expect(abs(at60.velocity - at120.velocity) < 1e-9)
    }

    @Test func settlesWithoutOvershoot() {
        var spring = CriticallyDampedSpring(position: 0, response: 0.1)
        var maximum = 0.0
        for _ in 0..<240 {
            spring.step(toward: 1, dt: 1.0 / 120)
            maximum = max(maximum, spring.position)
        }
        #expect(maximum <= 1 + 1e-12)
        #expect(abs(spring.position - 1) <= 1e-6)
        #expect(abs(spring.velocity) <= 1e-4)
    }

    @Test func errorAfterOneResponseIsAboutOnePointFourPercent() {
        var spring = CriticallyDampedSpring(position: 0, response: 0.2)
        spring.step(toward: 1, dt: 0.2)
        #expect(abs((1 - spring.position) - 0.0136) < 0.001)
    }

    @Test func retargetingKeepsVelocityContinuous() {
        var spring = CriticallyDampedSpring(position: 0, response: 0.1)
        advance(&spring, toward: 100, seconds: 0.03, hz: 120)
        let velocityBefore = spring.velocity
        #expect(velocityBefore > 0)
        spring.step(toward: 0, dt: 1e-6)
        #expect(abs(spring.velocity - velocityBefore) / velocityBefore < 0.01)
    }

    @Test func zeroOrNegativeTimeStepDoesNothing() {
        var spring = CriticallyDampedSpring(position: 3, response: 0.1)
        spring.step(toward: 10, dt: 0)
        spring.step(toward: 10, dt: -1)
        #expect(spring.position == 3)
        #expect(spring.velocity == 0)
    }

    @Test func resetClearsVelocity() {
        var spring = CriticallyDampedSpring(position: 0, response: 0.1)
        advance(&spring, toward: 50, seconds: 0.02, hz: 120)
        spring.reset(to: 7)
        #expect(spring.position == 7)
        #expect(spring.velocity == 0)
    }
}
