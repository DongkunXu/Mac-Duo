import Foundation

/// Describes a pluggable component (motion model or effect) to the UI and to preset storage.
public struct ComponentInfo: Sendable, Identifiable, Hashable {
    /// Stable identifier used in stored settings; never change it once shipped.
    public let id: String
    public let name: String
    public let summary: String
    public let parameters: [ParameterSpec]

    public init(id: String, name: String, summary: String, parameters: [ParameterSpec]) {
        precondition(Set(parameters.map(\.id)).count == parameters.count, "duplicate parameter id in \(id)")
        self.id = id
        self.name = name
        self.summary = summary
        self.parameters = parameters
    }
}

/// Turns lid samples into the fold state an effect renders. `update` is called once per display
/// frame while the app is awake, with the newest sample (nil when the sensor is unavailable); the
/// next call may follow a gap of any length.
public protocol MotionModel {
    static var info: ComponentInfo { get }
    /// The parameter setting the angle at and above which the model shows nothing, if it has one.
    /// The menu bar offers it directly and the arming detector wakes the app around it.
    static var releaseAngleParameter: ParameterSpec? { get }
    init()
    mutating func update(sample: LidSample?, at time: TimeInterval, parameters: ParameterValues) -> FoldState
}

public extension MotionModel {
    static var releaseAngleParameter: ParameterSpec? { nil }

    static func releaseAngle(for parameters: ParameterValues) -> Double {
        guard let spec = releaseAngleParameter else { return FoldLimits.releaseAngle }
        return min(parameters[spec], FoldLimits.releaseAngle)
    }

    /// Samples older than this count as missing.
    static var staleSampleLimit: TimeInterval { 0.5 }

    static func isFresh(_ sample: LidSample?, at time: TimeInterval) -> Bool {
        guard let sample else { return false }
        return time - sample.timestamp <= staleSampleLimit
    }
}
