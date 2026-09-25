import Foundation
import IOKit.hid
import MacDuoKit
import QuartzCore
import Synchronization

/// Polls the lid-angle sensor on a dedicated thread and publishes the newest sample. Only that
/// thread touches IOHID objects. Pushed reports arrive once per second, which is too slow, and the
/// sensor is polled (docs/sensor.md). Every reading is also handed to `onSample` on that thread.
final class LidSensor: Sendable {
    enum Status: Sendable, Equatable, CustomStringConvertible {
        case stopped
        case searching
        case running(LidSample.Resolution)
        case unavailable(String)

        var description: String {
            switch self {
            case .stopped: String(localized: "Stopped")
            case .searching: String(localized: "Searching for the sensor")
            case .running(.fine): String(localized: "Running · 0.01° resolution")
            case .running(.coarse): String(localized: "Running · 1° resolution")
            case .unavailable(let reason): String(localized: "Unavailable · \(reason)")
            }
        }
    }

    /// How often the sensor is read. It refreshes about every 100 ms regardless; reading faster
    /// only timestamps each new value more precisely.
    enum Cadence: Sendable, Equatable {
        /// 5 reads per second at utility priority, enough to notice deliberate lid movement.
        case dormant
        /// 120 reads per second, timestamping each update within about 8 ms.
        case awake

        var interval: TimeInterval {
            switch self {
            case .dormant: 0.2
            case .awake: 1.0 / 120
            }
        }

        var qos: qos_class_t {
            switch self {
            case .dormant: QOS_CLASS_UTILITY
            case .awake: QOS_CLASS_USER_INTERACTIVE
            }
        }
    }

    private struct State {
        var latest: LidSample?
        var status: Status = .stopped
        var cadence: Cadence = .dormant
        var generation = 0
    }

    private let state = Mutex(State())
    /// Cuts the polling thread's wait short on a cadence change or stop.
    private let wake = DispatchSemaphore(value: 0)
    private let onSample: @Sendable (LidSample) -> Void
    private let onStatusChange: @MainActor @Sendable (Status) -> Void

    /// Reads must keep failing this long, and `failureCount` times in a row, before the device counts as lost.
    private static let failureWindow: TimeInterval = 0.25
    private static let failureCount = 2
    private static let reconnectInterval: TimeInterval = 2

    init(onSample: @escaping @Sendable (LidSample) -> Void,
         onStatusChange: @escaping @MainActor @Sendable (Status) -> Void) {
        self.onSample = onSample
        self.onStatusChange = onStatusChange
    }

    var latest: LidSample? { state.withLock { $0.latest } }
    var cadence: Cadence { state.withLock { $0.cadence } }

    func setCadence(_ cadence: Cadence) {
        let changed: Bool = state.withLock { s in
            guard s.cadence != cadence else { return false }
            s.cadence = cadence
            return true
        }
        if changed { wake.signal() }
    }

    func start() {
        let generation: Int? = state.withLock { s in
            guard s.status == .stopped else { return nil }
            s.generation += 1
            s.status = .searching
            return s.generation
        }
        guard let generation else { return }
        notify(.searching)
        let thread = Thread { [self] in run(generation: generation) }
        thread.name = "MacDuo.LidSensor"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        let changed: Bool = state.withLock { s in
            guard s.status != .stopped else { return false }
            s.generation += 1
            s.status = .stopped
            s.latest = nil
            return true
        }
        guard changed else { return }
        wake.signal()
        notify(.stopped)
    }

    // MARK: Polling thread

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation }
    }

    private func run(generation: Int) {
        var connection: SensorConnection?
        var failingSince: TimeInterval?
        var consecutiveFailures = 0
        var appliedQoS: qos_class_t?
        var nextTick = CACurrentMediaTime()
        defer { connection?.close() }
        // Drain a signal a previous run's stop may have left behind.
        while wake.wait(timeout: .now()) == .success {}

        while isCurrent(generation) {
            let cadence = self.cadence
            if appliedQoS != cadence.qos {
                pthread_set_qos_class_self_np(cadence.qos, 0)
                appliedQoS = cadence.qos
            }

            if connection == nil {
                switch SensorConnection.open() {
                case .success(let opened):
                    connection = opened
                    failingSince = nil
                    consecutiveFailures = 0
                    publish(.running(opened.resolution), generation: generation)
                case .failure(let error):
                    publish(.unavailable(error.description), generation: generation)
                    _ = wake.wait(timeout: .now() + Self.reconnectInterval)
                    nextTick = CACurrentMediaTime()
                    continue
                }
            }

            if let active = connection {
                if let sample = active.read() {
                    failingSince = nil
                    consecutiveFailures = 0
                    let current: Bool = state.withLock { s in
                        guard s.generation == generation else { return false }
                        s.latest = sample
                        return true
                    }
                    if current { onSample(sample) }
                } else {
                    let now = CACurrentMediaTime()
                    consecutiveFailures += 1
                    let since = failingSince ?? now
                    failingSince = since
                    if consecutiveFailures >= Self.failureCount, now - since >= Self.failureWindow {
                        active.close()
                        connection = nil
                        state.withLock { s in
                            if s.generation == generation { s.latest = nil }
                        }
                        publish(.unavailable(String(localized: "the sensor stopped responding")), generation: generation)
                    }
                }
            }

            nextTick += cadence.interval
            let now = CACurrentMediaTime()
            if nextTick < now {
                // Fell behind (for example across sleep); resume from now without a burst of reads.
                nextTick = now
            } else if wake.wait(timeout: .now() + (nextTick - now)) == .success {
                // Cadence changed or stopping: read (or exit) right away.
                nextTick = CACurrentMediaTime()
            }
        }
    }

    private func publish(_ status: Status, generation: Int) {
        let changed: Bool = state.withLock { s in
            guard s.generation == generation, s.status != status else { return false }
            s.status = status
            return true
        }
        if changed { notify(status) }
    }

    private func notify(_ status: Status) {
        let callback = onStatusChange
        Task { @MainActor in callback(status) }
    }
}

// MARK: - HID connection (confined to the polling thread)

private struct SensorError: Error, CustomStringConvertible {
    let description: String
}

private final class SensorConnection {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    let resolution: LidSample.Resolution
    private var buffer = [UInt8](repeating: 0, count: 8)
    private var isOpen = true

    private static let options = IOOptionBits(kIOHIDOptionsTypeNone)

    private init(manager: IOHIDManager, device: IOHIDDevice, resolution: LidSample.Resolution) {
        self.manager = manager
        self.device = device
        self.resolution = resolution
    }

    static func open() -> Result<SensorConnection, SensorError> {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, options)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: LidReport.vendorID,
            kIOHIDProductIDKey: LidReport.productID,
            kIOHIDPrimaryUsagePageKey: LidReport.usagePage,
            kIOHIDPrimaryUsageKey: LidReport.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let managerResult = IOHIDManagerOpen(manager, options)
        guard managerResult == kIOReturnSuccess else {
            return .failure(SensorError(description: String(localized: "could not open the HID manager (\(hex(managerResult)))")))
        }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard !devices.isEmpty else {
            IOHIDManagerClose(manager, options)
            return .failure(SensorError(description: String(localized: "this Mac has no lid-angle sensor")))
        }

        var lastError = String(localized: "the sensor returned no readable angle")
        for device in devices {
            let openResult = IOHIDDeviceOpen(device, options)
            guard openResult == kIOReturnSuccess else {
                lastError = String(localized: "could not open the sensor (\(hex(openResult)))")
                continue
            }
            for resolution in [LidSample.Resolution.fine, .coarse] {
                let candidate = SensorConnection(manager: manager, device: device, resolution: resolution)
                if candidate.read() != nil { return .success(candidate) }
                candidate.isOpen = false
            }
            IOHIDDeviceClose(device, options)
        }
        IOHIDManagerClose(manager, options)
        return .failure(SensorError(description: lastError))
    }

    func read() -> LidSample? {
        guard isOpen else { return nil }
        var length = CFIndex(buffer.count)
        let angle: Double?
        switch resolution {
        case .fine:
            guard IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(LidReport.fineReportID), &buffer, &length) == kIOReturnSuccess else { return nil }
            angle = LidReport.decodeFine(buffer.prefix(Int(length)))
        case .coarse:
            guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(LidReport.coarseReportID), &buffer, &length) == kIOReturnSuccess else { return nil }
            angle = LidReport.decodeCoarse(buffer.prefix(Int(length)))
        }
        return angle.map { LidSample(angle: $0, timestamp: CACurrentMediaTime(), resolution: resolution) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        IOHIDDeviceClose(device, Self.options)
        IOHIDManagerClose(manager, Self.options)
    }

    private static func hex(_ code: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: code), radix: 16, uppercase: true)
    }
}
