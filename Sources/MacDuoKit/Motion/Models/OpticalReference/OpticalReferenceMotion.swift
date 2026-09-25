import Foundation

/// The desktop is pinned to a plane at the release angle and the lid is glass rotating away from
/// it. At and above the release angle nothing is drawn. A lid held still below it is cleared
/// after a hold time and the effect returns once the lid moves again.
///
/// Between the sensor's ~10 Hz updates the lid is played back slightly late and interpolated
/// (`SampleInterpolator`). A lid that stops just above the release angle stays clear. Sensor dither is absorbed by the dead band and the still tolerance.
public struct OpticalReferenceMotion: MotionModel {
    public static let releaseAngle = ParameterSpec(
        id: "releaseAngle", name: String(localized: "Release above", bundle: #bundle),
        range: 60...FoldLimits.releaseAngle, step: 0.5, default: 95, unit: "°",
        detail: String(localized: "At and above this angle the desktop is untouched; below it the glass tilts away from a content plane pinned here.", bundle: #bundle))
    public static let holdClear = ParameterSpec(
        id: "holdClear", name: String(localized: "Clear after holding still", bundle: #bundle),
        range: 0.3...10, step: 0.1, default: 2, unit: "s",
        detail: String(localized: "A lid held still below the release angle is cleared after this long.", bundle: #bundle))
    public static let clearResponse = ParameterSpec(
        id: "clearResponse", name: String(localized: "Clear and return speed", bundle: #bundle),
        range: 0.05...2, step: 0.01, default: 0.3, unit: "s")
    public static let stillTolerance = ParameterSpec(
        id: "stillTolerance", name: String(localized: "Still tolerance", bundle: #bundle),
        range: 0.1...3, step: 0.05, default: 0.3, unit: "°",
        detail: String(localized: "Raised to at least 1° when the sensor only reports whole degrees.", bundle: #bundle))
    public static let motionVelocity = ParameterSpec(
        id: "motionVelocity", name: String(localized: "Motion threshold", bundle: #bundle),
        range: 0.5...10, step: 0.1, default: 2, unit: "°/s",
        detail: String(localized: "Lid speed above which the lid counts as moving, which holds off the clear.", bundle: #bundle))
    public static let interpolationDelay = ParameterSpec(
        id: "interpolationDelay", name: String(localized: "Interpolation delay", bundle: #bundle),
        range: 0...0.25, step: 0.005, default: 0.1, unit: "s",
        detail: String(localized: "How far behind real time the lid is played back. About one sensor interval (0.1 s) gives continuous motion; 0 follows each sensor update directly.", bundle: #bundle))
    public static let response = ParameterSpec(
        id: "response", name: String(localized: "Lid smoothing", bundle: #bundle),
        range: 0.01...0.3, step: 0.005, default: 0.03, unit: "s",
        detail: String(localized: "Spring response of the glass following the lid.", bundle: #bundle))
    public static let deadband = ParameterSpec(
        id: "deadband", name: String(localized: "Noise dead band", bundle: #bundle),
        range: 0...1.5, step: 0.05, default: 0.1, unit: "°",
        detail: String(localized: "Raised to at least 0.6° when the sensor only reports whole degrees.", bundle: #bundle))
    public static let engageThreshold = ParameterSpec(
        id: "engageThreshold", name: String(localized: "Show overlay beyond", bundle: #bundle),
        range: 0.05...5, step: 0.05, default: 0.4, unit: "°",
        detail: String(localized: "Never smaller than the dead band.", bundle: #bundle))

    public static let releaseAngleParameter: ParameterSpec? = releaseAngle

    public static let info = ComponentInfo(
        id: "optical-reference",
        name: String(localized: "Optical reference", bundle: #bundle),
        summary: String(localized: "Nothing at or above the release angle; below it the lid is glass rotating away from the desktop pinned there.", bundle: #bundle),
        parameters: [releaseAngle, holdClear, clearResponse, stillTolerance, motionVelocity, interpolationDelay,
                     response, deadband, engageThreshold])

    /// Longest frame interval integrated in one step.
    static let maxStep: TimeInterval = 0.1
    /// A change beyond the still tolerance within this window counts as ongoing motion.
    static let motionWindow: TimeInterval = 0.3
    /// Minimum dead band and still tolerance for whole-degree sensor data.
    static let coarseDeadband = 0.6
    static let coarseStillTolerance = 1.0

    private var lid: CriticallyDampedSpring?
    private var clear = CriticallyDampedSpring(position: 0, response: 0.3)
    private var deadBand = DeadBand()
    private var tracker = AngleTracker()
    private var interpolator = SampleInterpolator()
    private var stillness = StillnessDetector()
    private var lastTime: TimeInterval?
    private var visible = false

    public init() {}

    public mutating func update(sample: LidSample?, at time: TimeInterval, parameters p: ParameterValues) -> FoldState {
        guard let sample, Self.isFresh(sample, at: time) else {
            return suspend()
        }
        let coarse = sample.resolution == .coarse
        let band = max(p[Self.deadband], coarse ? Self.coarseDeadband : 0)
        let tolerance = max(p[Self.stillTolerance], coarse ? Self.coarseStillTolerance : 0)
        let release = min(p[Self.releaseAngle], FoldLimits.releaseAngle)

        var tracked = deadBand.apply(sample.angle, band: band)
        // The dead band could otherwise hold a lid resting exactly at the release angle just below it.
        if sample.angle >= release { tracked = max(tracked, release) }
        tracker.ingest(angle: tracked, at: sample.timestamp)
        stillness.ingest(angle: tracked, at: sample.timestamp, tolerance: tolerance)
        interpolator.ingest(angle: tracked, at: sample.timestamp)

        let dt = lastTime.map { min(max(time - $0, 0), Self.maxStep) } ?? 0
        lastTime = time

        let moving = stillness.movedRecently(at: time, within: Self.motionWindow)
            || abs(tracker.velocity(at: time)) > p[Self.motionVelocity]
        let stillFor = stillness.stillDuration(at: time)

        let target = interpolator.value(at: time, delay: p[Self.interpolationDelay]) ?? tracked
        var lidSpring = lid ?? CriticallyDampedSpring(position: target, response: p[Self.response])
        lidSpring.response = p[Self.response]
        lidSpring.step(toward: target, dt: dt)
        lid = lidSpring
        let lidAngle = lidSpring.position

        // Clearing only builds up below the release angle; a close from above starts with the full effect.
        let shouldClear = !moving && stillFor >= p[Self.holdClear] && tracked < release
        clear.response = p[Self.clearResponse]
        clear.step(toward: shouldClear ? 1 : 0, dt: dt)
        let clearAmount = min(max(clear.position, 0), 1)

        let deviation = min(lidAngle - release, 0) * (1 - clearAmount)
        let threshold = max(p[Self.engageThreshold], band)
        visible = abs(deviation) > (visible ? threshold * 0.5 : threshold)

        return FoldState(lidAngle: lidAngle, referenceAngle: lidAngle - deviation, isVisible: visible)
    }

    /// Sensor data missing or stale (for example across sleep): hide and forget the lid's motion.
    private mutating func suspend() -> FoldState {
        let angle = lid?.position ?? 0
        lid = nil
        clear.reset(to: 0)
        deadBand.reset()
        tracker.reset()
        interpolator.reset()
        stillness.reset()
        lastTime = nil
        visible = false
        return .hidden(at: angle)
    }
}
