import Foundation

/// Decides from lid samples alone when the dormant app has to wake up, reacting only to deliberate
/// lid movement, never to a knock or desk wobble.
///
/// Movement is measured from where the lid last came to rest (within `restTolerance` for
/// `settleTime`). A knock that springs back adds up to nothing; a real close adds up at any speed.
/// The movement needed depends on where the lid is:
/// - at or above `releaseAngle + approachMargin`: ignored, the effect cannot appear there;
/// - between that and the release angle: closing by `travel`, which gets the effect ready in time;
/// - below the release angle: moving by `effectZoneTravel` either way, larger than `travel` to
///   ignore small adjustments of a lid used at a low angle.
public struct ArmingDetector: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        public var releaseAngle: Double
        public var approachMargin: Double
        public var travel: Double
        public var effectZoneTravel: Double
        public var restTolerance: Double
        public var settleTime: TimeInterval

        public init(releaseAngle: Double = FoldLimits.releaseAngle, approachMargin: Double = 15,
                    travel: Double = 2.5, effectZoneTravel: Double = 6,
                    restTolerance: Double = 0.5, settleTime: TimeInterval = 0.6) {
            precondition(approachMargin >= 0 && travel > 0 && effectZoneTravel > 0 && restTolerance >= 0 && settleTime > 0)
            self.releaseAngle = releaseAngle
            self.approachMargin = approachMargin
            self.travel = travel
            self.effectZoneTravel = effectZoneTravel
            self.restTolerance = restTolerance
            self.settleTime = settleTime
        }
    }

    /// Whole-degree data dithers by one degree at rest.
    static let coarseRestTolerance = 1.0

    struct Rest: Sendable, Equatable {
        var angle: Double
        var since: TimeInterval
    }

    public var configuration: Configuration
    private var reference: Double?
    private var candidate: Rest?
    private var lastTime: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Returns true if the lid is moving deliberately enough to wake up. The first sample after
    /// creation or `reset()` is taken as the rest position.
    public mutating func ingest(_ sample: LidSample) -> Bool {
        let angle = sample.angle
        let time = sample.timestamp
        guard angle.isFinite else { return false }
        if let lastTime, time <= lastTime { return false }
        lastTime = time

        let c = configuration
        let tolerance = max(c.restTolerance, sample.resolution == .coarse ? Self.coarseRestTolerance : 0)
        guard let current = reference, let rest = candidate else {
            reference = angle
            candidate = Rest(angle: angle, since: time)
            return false
        }
        var base = current
        if abs(angle - rest.angle) <= tolerance {
            if time - rest.since >= c.settleTime {
                base = rest.angle
                reference = base
            }
        } else {
            candidate = Rest(angle: angle, since: time)
        }

        let net = angle - base
        if angle >= c.releaseAngle + c.approachMargin {
            return false
        }
        if angle >= c.releaseAngle {
            return -net >= c.travel
        }
        return abs(net) >= c.effectZoneTravel
    }

    public mutating func reset() {
        reference = nil
        candidate = nil
        lastTime = nil
    }
}
