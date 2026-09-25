import Foundation

/// Suppresses sensor dither: the tracked value moves only when the raw value leaves a band around it.
public struct DeadBand: Sendable, Equatable {
    public private(set) var value: Double?

    public init() {}

    public mutating func apply(_ raw: Double, band: Double) -> Double {
        guard let current = value, band > 0 else {
            value = raw
            return raw
        }
        let next = min(max(current, raw - band), raw + band)
        value = next
        return next
    }

    public mutating func reset() { value = nil }
}

/// Lid velocity measured between distinct readings. The sensor is polled far faster than it
/// refreshes (about 10 Hz); repeated values are skipped and each change is stamped with the time
/// it was first seen.
public struct AngleTracker: Sendable, Equatable {
    public private(set) var angle: Double?
    public private(set) var changeTime: TimeInterval = 0
    private var rawVelocity: Double = 0

    /// Time constant of the velocity low-pass filter.
    public var velocityTimeConstant: TimeInterval
    /// Longest interval treated as continuous motion between two changes.
    public var maxChangeInterval: TimeInterval

    public init(velocityTimeConstant: TimeInterval = 0.06, maxChangeInterval: TimeInterval = 0.15) {
        precondition(velocityTimeConstant > 0 && maxChangeInterval > 0)
        self.velocityTimeConstant = velocityTimeConstant
        self.maxChangeInterval = maxChangeInterval
    }

    public mutating func ingest(angle newAngle: Double, at time: TimeInterval) {
        guard let previous = angle else {
            angle = newAngle
            changeTime = time
            return
        }
        guard newAngle != previous else { return }
        let interval = min(max(time - changeTime, 1e-4), maxChangeInterval)
        let instant = (newAngle - previous) / interval
        let alpha = 1 - exp(-interval / velocityTimeConstant)
        rawVelocity += alpha * (instant - rawVelocity)
        angle = newAngle
        changeTime = time
    }

    /// Degrees per second, decaying once no change has been seen for `maxChangeInterval`.
    public func velocity(at time: TimeInterval) -> Double {
        let idle = time - changeTime - maxChangeInterval
        guard idle > 0 else { return rawVelocity }
        return rawVelocity * exp(-idle / velocityTimeConstant)
    }

    public mutating func reset() {
        angle = nil
        changeTime = 0
        rawVelocity = 0
    }
}

/// Measures how long the angle has stayed within a tolerance of an anchor.
public struct StillnessDetector: Sendable, Equatable {
    public private(set) var anchor: Double?
    public private(set) var anchorTime: TimeInterval = 0
    /// When the angle last left the tolerance band; nil until it has actually moved.
    public private(set) var lastMovement: TimeInterval?

    public init() {}

    public mutating func ingest(angle: Double, at time: TimeInterval, tolerance: Double) {
        guard let current = anchor else {
            anchor = angle
            anchorTime = time
            return
        }
        guard abs(angle - current) > tolerance else { return }
        anchor = angle
        anchorTime = time
        lastMovement = time
    }

    public func stillDuration(at time: TimeInterval) -> TimeInterval {
        anchor == nil ? 0 : max(time - anchorTime, 0)
    }

    public func movedRecently(at time: TimeInterval, within window: TimeInterval) -> Bool {
        guard let lastMovement else { return false }
        return time - lastMovement < window
    }

    public mutating func reset() {
        anchor = nil
        anchorTime = 0
        lastMovement = nil
    }
}
