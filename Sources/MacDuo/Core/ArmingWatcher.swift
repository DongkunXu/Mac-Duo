import MacDuoKit
import Synchronization

/// Runs the arming detector on the sensor thread while the app is dormant and wakes the main actor
/// once when the lid moves deliberately.
final class ArmingWatcher: Sendable {
    private struct State {
        var detector: ArmingDetector
        var enabled = false
    }

    private let state: Mutex<State>
    private let onArm: @MainActor @Sendable () -> Void

    init(configuration: ArmingDetector.Configuration = ArmingDetector.Configuration(),
         onArm: @escaping @MainActor @Sendable () -> Void) {
        state = Mutex(State(detector: ArmingDetector(configuration: configuration)))
        self.onArm = onArm
    }

    func setReleaseAngle(_ angle: Double) {
        state.withLock { s in
            guard s.detector.configuration.releaseAngle != angle else { return }
            s.detector.configuration.releaseAngle = angle
            s.detector.reset()
        }
    }

    func enable() {
        state.withLock { s in
            s.detector.reset()
            s.enabled = true
        }
    }

    func disable() {
        state.withLock { $0.enabled = false }
    }

    func observe(_ sample: LidSample) {
        let fire: Bool = state.withLock { s in
            guard s.enabled, s.detector.ingest(sample) else { return false }
            // One wake-up per arming; the owner re-enables it after going dormant again.
            s.enabled = false
            return true
        }
        guard fire else { return }
        let callback = onArm
        Task { @MainActor in callback() }
    }
}
