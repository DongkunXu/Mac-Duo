import AppKit
import MacDuoKit
import Observation

/// Decides when the engine runs, applies the user's configuration and presets, persists settings
/// and publishes status for the UI.
///
/// While the engine should run it is either dormant (only the sensor, read 5 times a second) or
/// awake (capture, display link, 120 Hz sensor reads, drawing below the release angle). Deliberate
/// lid movement (`ArmingDetector`) wakes it; the render host reports idle once nothing has been
/// drawn and the lid has been still for a second (`DormancyTimer`).
@Observable
@MainActor
final class AppModel {
    enum Power: Equatable, CustomStringConvertible {
        case off
        case dormant
        case awake

        var description: String {
            switch self {
            case .off: String(localized: "Stopped")
            case .dormant: String(localized: "Dormant · watching the lid")
            case .awake: String(localized: "Awake")
            }
        }
    }

    // MARK: Published state

    private(set) var isEnabled: Bool
    private(set) var isPaused = false
    private(set) var power: Power = .off
    var isRunning: Bool { power != .off }
    private(set) var sensorStatus: LidSensor.Status = .stopped
    private(set) var hasCapturePermission = DisplayCapture.hasPermission
    private(set) var suspensions: Set<SystemMonitor.Suspension> = []
    private(set) var hasBuiltInDisplay = NSScreen.builtIn != nil
    private(set) var problem: String?
    private(set) var captureProblem: String?
    private(set) var engineProblem: String?
    private(set) var hotKeyProblem: String?
    private(set) var liveAngle: Double?
    private(set) var liveState: FoldState?
    private(set) var language: AppLanguage
    private(set) var selection: Selection
    private(set) var userPresets: [Preset]

    let pauseShortcut = GlobalHotKey.pauseDescription
    /// The language this process was launched with; a change takes effect on relaunch.
    @ObservationIgnored private let launchLanguage: AppLanguage
    var languageNeedsRelaunch: Bool { language != launchLanguage }

    /// The problem to show, if any: engine problems always, others only while enabled.
    var visibleProblem: String? {
        engineProblem ?? (isEnabled ? captureProblem ?? problem : nil)
    }

    // MARK: Internals

    @ObservationIgnored private var engine: Engine?
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var liveReadoutViewers: Set<UUID> = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var captureQueue: Task<Void, Never>?
    @ObservationIgnored private var captureFailures = 0
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var permissionRequested = false
    @ObservationIgnored private let defaults: UserDefaults

    /// How long the engine stays dormant before it also frees the overlay's GPU memory; waking is
    /// slower afterwards.
    private static let deepReleaseDelay: Duration = .seconds(30)

    private enum Keys {
        static let enabled = "enabled.v1"
        static let selection = "selection.v1"
        static let presets = "presets.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        let storedLanguage = AppLanguage.stored(in: defaults)
        language = storedLanguage
        launchLanguage = storedLanguage
        let stored = Self.decode(Selection.self, forKey: Keys.selection, in: defaults)
            ?? Selection(motionID: ComponentRegistry.defaultMotionID, effectID: ComponentRegistry.defaultEffectID)
        var loaded = stored
        if ComponentRegistry.motionModel(id: loaded.motionID) == nil { loaded.motionID = ComponentRegistry.defaultMotionID }
        if ComponentRegistry.effect(id: loaded.effectID) == nil { loaded.effectID = ComponentRegistry.defaultEffectID }
        loaded.prune(keeping: ComponentRegistry.parameterSpecsByComponent)
        selection = loaded
        userPresets = Self.decode([Preset].self, forKey: Keys.presets, in: defaults) ?? []
        if loaded != stored { persistSelection() }
    }

    // MARK: Lifecycle

    func launch() {
        guard !launched else { return }
        launched = true
        monitor.onSuspensionsChange = { [weak self] suspensions, added in
            self?.suspensionsChanged(suspensions, added: added)
        }
        monitor.onScreenConfigurationChange = { [weak self] in self?.screenConfigurationChanged() }
        monitor.start()
        registerHotKey(retryOnFailure: true)
        do {
            engine = try Engine(
                onSensorStatus: { [weak self] status in self?.sensorStatus = status },
                onCaptureFailure: { [weak self] error in self?.captureFailed(error) },
                onArm: { [weak self] in self?.wake() })
        } catch {
            engineProblem = error.description
        }
        updateArmingReleaseAngle()
        reconcile()
    }

    func shutdown() {
        stop(keepingLastFrame: false)
        engine?.teardownDisplay()
        monitor.stop()
        hotKey?.unregister()
    }

    // MARK: User actions

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Keys.enabled)
        if enabled {
            problem = nil
            captureProblem = nil
            captureFailures = 0
        }
        reconcile()
    }

    /// Paused is dormant with the arming detector off.
    func togglePause() {
        isPaused.toggle()
        guard isRunning, let engine else { return }
        if isPaused {
            enterDormant()
            engine.arming.disable()
        } else {
            wake()
        }
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
        newLanguage.store(in: defaults)
    }

    func requestCapturePermission() {
        DisplayCapture.requestPermission()
        hasCapturePermission = DisplayCapture.hasPermission
        reconcile()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording grants take effect for a freshly launched process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    self.problem = String(localized: "Relaunch failed: \(error.localizedDescription)")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: Components and parameters

    var motionInfo: ComponentInfo? { ComponentRegistry.motionModel(id: selection.motionID)?.info }
    var effectInfo: ComponentInfo? { ComponentRegistry.effect(id: selection.effectID)?.info }

    var releaseAngleParameter: ParameterSpec? {
        ComponentRegistry.motionModel(id: selection.motionID)?.releaseAngleParameter
    }

    var releaseAngle: Double {
        guard let spec = releaseAngleParameter else { return FoldLimits.releaseAngle }
        return selection.motionParameters[spec]
    }

    func setReleaseAngle(_ angle: Double) {
        guard let spec = releaseAngleParameter else { return }
        setParameter(spec, to: angle, component: selection.motionID)
    }

    func parameters(for componentID: String) -> ParameterValues {
        selection.parameters(for: componentID)
    }

    func setParameter(_ spec: ParameterSpec, to value: Double, component componentID: String) {
        var values = selection.parameters(for: componentID)
        values[spec] = value
        selection.setParameters(values, for: componentID)
        persistSelection()
        pushParameters(of: componentID)
    }

    func resetParameters(component componentID: String) {
        selection.setParameters(ParameterValues(), for: componentID)
        persistSelection()
        pushParameters(of: componentID)
    }

    // MARK: Presets

    var builtInPresets: [Preset] { BuiltInPresets.all }

    /// Whether the live configuration is exactly `preset`.
    func isActive(_ preset: Preset) -> Bool {
        selection.motionID == preset.motionID && selection.effectID == preset.effectID
            && selection.motionParameters == preset.motionParameters
            && selection.effectParameters == preset.effectParameters
    }

    func apply(_ preset: Preset) {
        guard let motionType = ComponentRegistry.motionModel(id: preset.motionID),
              ComponentRegistry.effect(id: preset.effectID) != nil else {
            problem = String(localized: "Preset “\(preset.name)” uses a component that no longer exists.")
            return
        }
        selection.apply(preset)
        persistSelection()
        updateArmingReleaseAngle()
        guard let engine, let host = engine.host else { return }
        host.setMotion(motionType, parameters: selection.motionParameters)
        do {
            host.setEffect(try engine.effect(id: preset.effectID), parameters: selection.effectParameters)
        } catch {
            problem = error.description
        }
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userPresets.append(selection.snapshot(named: trimmed))
        persistPresets()
    }

    func renamePreset(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[index].name = trimmed
        persistPresets()
    }

    func deletePreset(_ id: UUID) {
        userPresets.removeAll { $0.id == id }
        persistPresets()
    }

    /// Replaces a user preset's contents with the live configuration.
    func updatePreset(_ id: UUID) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        var updated = selection.snapshot(named: userPresets[index].name)
        updated.id = id
        userPresets[index] = updated
        persistPresets()
    }

    // MARK: Engine control

    private var shouldRun: Bool {
        isEnabled && suspensions.isEmpty && hasBuiltInDisplay && engine != nil
    }

    private func reconcile() {
        if shouldRun, !isRunning {
            start()
        } else if !shouldRun, isRunning {
            // Across plain sleep the last desktop frame is kept for the first frames after waking.
            let sleepOnly = !suspensions.isEmpty && suspensions.isSubset(of: [.systemSleep, .displaySleep])
            stop(keepingLastFrame: sleepOnly)
        }
    }

    private func start() {
        guard let engine else { return }
        hasCapturePermission = DisplayCapture.hasPermission
        guard hasCapturePermission else {
            if !permissionRequested {
                permissionRequested = true
                DisplayCapture.requestPermission()
            }
            problem = String(localized: "Screen Recording permission is required. Grant it in System Settings, then relaunch Mac Duo.")
            return
        }
        do {
            try engine.prepareDisplay(
                selection: selection,
                onRenderFailure: { [weak self] reason in
                    guard let self else { return }
                    problem = String(localized: "Rendering: \(reason)")
                    enterDormant()
                },
                onIdle: { [weak self] in self?.enterDormant() })
        } catch {
            problem = error.description
            return
        }
        guard engine.overlay != nil else { return }
        engine.sensor.setCadence(.dormant)
        engine.sensor.start()
        power = .dormant
        updateLiveTimer()
        // Start awake: the lid may be moving right now, for example opening after sleep.
        wake()
    }

    private func wake() {
        guard power == .dormant, !isPaused, let engine, let host = engine.host,
              let displayID = engine.overlay?.displayID else { return }
        releaseTask?.cancel()
        releaseTask = nil
        power = .awake
        engine.arming.disable()
        engine.sensor.setCadence(.awake)
        host.start()
        enqueueCapture { [weak self] in
            do throws(CaptureError) {
                try await engine.capture.start(displayID: displayID)
                self?.captureStarted()
            } catch {
                self?.captureFailed(error)
            }
        }
    }

    private func enterDormant() {
        guard power == .awake, let engine else { return }
        power = .dormant
        engine.host?.stop()
        engine.sensor.setCadence(.dormant)
        if !isPaused { engine.arming.enable() }
        enqueueCapture { await engine.capture.stop(keepingLastFrame: false) }
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.deepReleaseDelay)
            guard !Task.isCancelled, let self, power == .dormant else { return }
            engine.host?.releaseIdleResources()
        }
    }

    private func stop(keepingLastFrame: Bool) {
        retryTask?.cancel()
        retryTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        guard let engine else { return }
        power = .off
        engine.arming.disable()
        engine.host?.stop()
        engine.host?.releaseIdleResources()
        engine.sensor.stop()
        updateLiveTimer()
        enqueueCapture { await engine.capture.stop(keepingLastFrame: keepingLastFrame) }
    }

    /// Runs capture starts and stops strictly in request order. A quick stop followed by a start
    /// always ends with the stream running.
    private func enqueueCapture(_ operation: @escaping @MainActor () async -> Void) {
        let previous = captureQueue
        captureQueue = Task {
            await previous?.value
            await operation()
        }
    }

    private func captureStarted() {
        captureFailures = 0
        captureProblem = nil
    }

    private func captureFailed(_ error: CaptureError) {
        if case .permissionDenied = error { hasCapturePermission = false }
        captureProblem = String(localized: "Capture: \(error.description)")
        guard isRunning else { return }
        stop(keepingLastFrame: false)
        captureFailures += 1
        let delay = min(60, 3 * pow(2, Double(captureFailures - 1)))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func suspensionsChanged(_ updated: Set<SystemMonitor.Suspension>, added: SystemMonitor.Suspension?) {
        suspensions = updated
        if added == .screenLocked || added == .sessionInactive {
            // Never keep a copy of the desktop across a lock or user switch.
            engine?.capture.discardFrames()
        }
        reconcile()
    }

    private func screenConfigurationChanged() {
        hasBuiltInDisplay = NSScreen.builtIn != nil
        engine?.capture.invalidateFilter()
        guard let engine, engine.overlay != nil, !engine.overlayMatchesDisplay else {
            reconcile()
            return
        }
        if isRunning { stop(keepingLastFrame: false) }
        engine.teardownDisplay()
        reconcile()
    }

    private func updateArmingReleaseAngle() {
        guard let engine, let type = ComponentRegistry.motionModel(id: selection.motionID) else { return }
        engine.arming.setReleaseAngle(type.releaseAngle(for: selection.motionParameters))
    }

    private func pushParameters(of componentID: String) {
        if componentID == selection.motionID { updateArmingReleaseAngle() }
        guard let host = engine?.host else { return }
        if componentID == selection.motionID { host.motionParameters = selection.motionParameters }
        if componentID == selection.effectID { host.effectParameters = selection.effectParameters }
    }

    private func registerHotKey(retryOnFailure: Bool) {
        do {
            hotKey = try GlobalHotKey(keyCode: GlobalHotKey.pauseKeyCode, modifiers: GlobalHotKey.pauseModifiers) { [weak self] in
                self?.togglePause()
            }
            hotKeyProblem = nil
        } catch {
            hotKeyProblem = String(localized: "Pause shortcut \(GlobalHotKey.pauseDescription) unavailable: \(error.description)")
            guard retryOnFailure else { return }
            // A previous instance that is relaunching may still hold the key for a moment.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.registerHotKey(retryOnFailure: false)
            }
        }
    }

    // MARK: Live readout

    func liveReadoutAppeared(_ viewer: UUID) {
        liveReadoutViewers.insert(viewer)
        updateLiveTimer()
    }

    func liveReadoutDisappeared(_ viewer: UUID) {
        liveReadoutViewers.remove(viewer)
        updateLiveTimer()
    }

    private func updateLiveTimer() {
        if isRunning, !liveReadoutViewers.isEmpty {
            startLiveTimer()
        } else {
            stopLiveTimer()
        }
    }

    private func startLiveTimer() {
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
        liveAngle = nil
        liveState = nil
    }

    private func refreshLive() {
        let angle = engine?.sensor.latest?.angle
        if angle != liveAngle { liveAngle = angle }
        let state = engine?.host?.lastState
        if state != liveState { liveState = state }
    }

    // MARK: Persistence

    private func persistSelection() {
        Self.encode(selection, forKey: Keys.selection, in: defaults)
    }

    private func persistPresets() {
        Self.encode(userPresets, forKey: Keys.presets, in: defaults)
    }

    private static func decode<T: Decodable>(_ type: T.Type, forKey key: String, in defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else {
            preconditionFailure("settings of type \(T.self) failed to encode")
        }
        defaults.set(data, forKey: key)
    }
}
