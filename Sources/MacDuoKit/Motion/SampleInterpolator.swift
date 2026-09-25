import Foundation

/// Rebuilds a continuous lid angle from the sensor's ~10 Hz value changes by playing them back a
/// fixed delay behind real time and interpolating linearly. The result stays within the measured
/// values, and a lid that stops does not overshoot.
public struct SampleInterpolator: Sendable, Equatable {
    struct Point: Sendable, Equatable {
        let time: TimeInterval
        let angle: Double
    }

    private var points: [Point] = []
    /// Typical time between sensor updates; a change after a longer gap is taken to have begun
    /// one typical interval earlier.
    public var typicalInterval: TimeInterval
    /// Gaps longer than this count as rests.
    public var restGap: TimeInterval
    private static let history: TimeInterval = 2

    public init(typicalInterval: TimeInterval = 0.1, restGap: TimeInterval = 0.25) {
        precondition(typicalInterval > 0 && restGap > typicalInterval)
        self.typicalInterval = typicalInterval
        self.restGap = restGap
    }

    public mutating func ingest(angle: Double, at time: TimeInterval) {
        if let last = points.last {
            guard angle != last.angle, time > last.time else { return }
            if time - last.time > restGap {
                points.append(Point(time: time - typicalInterval, angle: last.angle))
            }
        }
        points.append(Point(time: time, angle: angle))
        let cutoff = time - Self.history
        if let index = points.firstIndex(where: { $0.time >= cutoff }), index > 1 {
            // Keep one point before the cutoff so playback inside the window can still interpolate.
            points.removeFirst(index - 1)
        }
    }

    /// The angle `delay` seconds before `time`, nil before the first sample.
    public func value(at time: TimeInterval, delay: TimeInterval) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        let playhead = time - max(delay, 0)
        if playhead >= last.time { return last.angle }
        if playhead <= first.time { return first.angle }
        var index = points.count - 1
        while index > 0, points[index - 1].time > playhead { index -= 1 }
        let a = points[index - 1]
        let b = points[index]
        guard b.time > a.time else { return b.angle }
        return a.angle + (b.angle - a.angle) * (playhead - a.time) / (b.time - a.time)
    }

    public mutating func reset() {
        points.removeAll()
    }
}
