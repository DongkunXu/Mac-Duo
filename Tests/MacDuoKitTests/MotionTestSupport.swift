import Foundation
@testable import MacDuoKit

/// Drives a motion model the way the app does: display frames at `frameRate`, while the sensor
/// value only changes at `sensorRate` (it is polled every frame but updates less often).
struct MotionSimulator<Model: MotionModel> {
    var model = Model()
    var parameters = ParameterValues()
    var time: TimeInterval = 100
    var frameRate: Double = 120
    var sensorRate: Double = 10
    var resolution: LidSample.Resolution = .fine
    private var lastSensorUpdate: TimeInterval = -.infinity
    private var sensorValue: Double?
    private(set) var states: [FoldState] = []

    init(parameters: ParameterValues = ParameterValues()) {
        self.parameters = parameters
    }

    var last: FoldState { states.last! }

    /// Runs for `duration` seconds with the true lid angle given by `angle(t)` (t from 0 to 1 over the run).
    mutating func run(for duration: TimeInterval, angle: (Double) -> Double) {
        let frames = Int((duration * frameRate).rounded())
        for frame in 1...max(frames, 1) {
            time += 1 / frameRate
            let fraction = Double(frame) / Double(max(frames, 1))
            if sensorValue == nil || time - lastSensorUpdate >= 1 / sensorRate {
                var value = angle(fraction)
                if resolution == .coarse { value = value.rounded() }
                sensorValue = value
                lastSensorUpdate = time
            }
            let sample = LidSample(angle: sensorValue!, timestamp: time, resolution: resolution)
            states.append(model.update(sample: sample, at: time, parameters: parameters))
        }
    }

    mutating func hold(_ angle: Double, for duration: TimeInterval) {
        run(for: duration) { _ in angle }
    }

    mutating func sweep(from start: Double, to end: Double, over duration: TimeInterval) {
        run(for: duration) { start + (end - start) * $0 }
    }

    /// No sensor data for `duration` seconds (e.g. system sleep).
    mutating func gap(_ duration: TimeInterval) {
        time += duration
        sensorValue = nil
        states.append(model.update(sample: nil, at: time, parameters: parameters))
    }
}
