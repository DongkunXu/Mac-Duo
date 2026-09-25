import Foundation

/// Decides when the awake engine may go dormant: once nothing has been drawn and the lid has
/// stayed still for `delay`. Lid movement keeps it awake, which lets a slow close finish.
public struct DormancyTimer: Sendable, Equatable {
    public var delay: TimeInterval
    public var stillTolerance: Double

    /// Whole-degree data dithers by one degree at rest.
    static let coarseStillTolerance = 1.0

    /// Lid angle (nil while the sensor has no reading) the current idle period is measured from.
    private var anchor: Double?
    private var since: TimeInterval?

    public init(delay: TimeInterval = 1, stillTolerance: Double = 0.5) {
        precondition(delay >= 0 && stillTolerance >= 0)
        self.delay = delay
        self.stillTolerance = stillTolerance
    }

    /// Called once per frame; returns true once the engine has been idle for `delay`.
    public mutating func update(sample: LidSample?, isVisible: Bool, at time: TimeInterval) -> Bool {
        if isVisible {
            since = nil
            return false
        }
        let angle = sample?.angle
        let tolerance = max(stillTolerance, sample?.resolution == .coarse ? Self.coarseStillTolerance : 0)
        if let since, Self.isSameRest(angle, anchor, tolerance: tolerance) {
            return time - since >= delay
        }
        anchor = angle
        since = time
        return false
    }

    public mutating func reset() {
        anchor = nil
        since = nil
    }

    private static func isSameRest(_ angle: Double?, _ anchor: Double?, tolerance: Double) -> Bool {
        switch (angle, anchor) {
        case (nil, nil): true
        case let (angle?, anchor?): abs(angle - anchor) <= tolerance
        default: false
        }
    }
}
