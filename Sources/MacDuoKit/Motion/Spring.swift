import Foundation

/// A critically damped spring integrated in closed form: the result depends only on elapsed time,
/// not on how it is divided into steps, and retargeting keeps the current velocity.
public struct CriticallyDampedSpring: Sendable, Equatable {
    public private(set) var position: Double
    public private(set) var velocity: Double
    /// Seconds until the error has decayed to about 1.4 %.
    public var response: Double {
        didSet { precondition(response > 0, "spring response must be positive") }
    }

    public init(position: Double, response: Double) {
        precondition(response > 0, "spring response must be positive")
        self.position = position
        self.velocity = 0
        self.response = response
    }

    private var omega: Double { 2 * .pi / response }

    public mutating func step(toward target: Double, dt: Double) {
        guard dt > 0 else { return }
        let w = omega
        let error = position - target
        let c = velocity + w * error
        let decay = exp(-w * dt)
        position = target + (error + c * dt) * decay
        velocity = (velocity - w * c * dt) * decay
    }

    public mutating func reset(to value: Double) {
        position = value
        velocity = 0
    }
}
