import AppKit
import MacDuoKit
import Metal
import QuartzCore

/// Once per display refresh: advances the motion model, decides visibility, rebuilds the blur
/// pyramid for a new desktop frame, lets the effect draw, and presents. The overlay is revealed
/// only after its first frame is presented; any GPU error or persistent lack of drawables hides it
/// immediately and reports.
@MainActor
final class RenderHost: NSObject {
    private let resources: EffectResources
    private let queue: MTLCommandQueue
    private let pyramid: BlurPyramid
    private let sensor: LidSensor
    private let capture: DisplayCapture
    private let overlay: OverlayWindow
    private let geometry: DisplayGeometry
    private let onFailure: (String) -> Void
    private let onIdle: () -> Void
    private var dormancy = DormancyTimer()

    private var link: CADisplayLink?
    private var motion: any MotionModel
    private var effect: any Effect
    var motionParameters: ParameterValues
    var effectParameters: ParameterValues

    /// At most two frames in flight. A busy GPU skips a frame and the main thread keeps running.
    private let inFlight = DispatchSemaphore(value: 2)
    private var showGeneration = 0
    private var revealPending = false
    private var drawableFailures = 0
    private var preparedSequence: UInt64?
    private var effectChanged = true
    private(set) var lastState: FoldState?

    private static let drawableFailureLimit = 30

    init(resources: EffectResources, queue: MTLCommandQueue, pyramid: BlurPyramid, sensor: LidSensor,
         capture: DisplayCapture, overlay: OverlayWindow, geometry: DisplayGeometry,
         motion: any MotionModel, motionParameters: ParameterValues,
         effect: any Effect, effectParameters: ParameterValues,
         onFailure: @escaping (String) -> Void, onIdle: @escaping () -> Void) {
        self.onIdle = onIdle
        self.resources = resources
        self.queue = queue
        self.pyramid = pyramid
        self.sensor = sensor
        self.capture = capture
        self.overlay = overlay
        self.geometry = geometry
        self.motion = motion
        self.motionParameters = motionParameters
        self.effect = effect
        self.effectParameters = effectParameters
        self.onFailure = onFailure
    }

    func start() {
        guard link == nil else { return }
        overlay.unpark()
        primeDrawables()
        let displayLink = overlay.screen.displayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(max(overlay.screen.maximumFramesPerSecond, 60))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
        dormancy.reset()
    }

    /// Stops drawing and keeps GPU memory for a quick wake; see `releaseIdleResources()`.
    func stop() {
        link?.invalidate()
        link = nil
        hide()
        capture.setRate(.idle)
    }

    /// Frees what a stopped host still holds: the drawable pool and the blur pyramid.
    func releaseIdleResources() {
        guard link == nil else { return }
        overlay.park()
        pyramid.release()
        effectChanged = true
    }

    /// Allocates the drawable pool up front; after a release it takes several milliseconds.
    private func primeDrawables() {
        for _ in 0..<3 {
            autoreleasepool { _ = overlay.metalLayer.nextDrawable() }
        }
    }

    func setMotion(_ type: any MotionModel.Type, parameters: ParameterValues) {
        motion = type.init()
        motionParameters = parameters
    }

    func setEffect(_ newEffect: any Effect, parameters: ParameterValues) {
        effect = newEffect
        effectParameters = parameters
        effectChanged = true
    }

    func hide() {
        if overlay.isShown {
            overlay.hide()
            showGeneration += 1
        }
        revealPending = false
        drawableFailures = 0
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        // The release rule (`FoldLimits`) is each motion model's responsibility; it is not masked here.
        let sample = sensor.latest
        let state = motion.update(sample: sample, at: displayLink.targetTimestamp, parameters: motionParameters)
        lastState = state
        if dormancy.update(sample: sample, isVisible: state.isVisible, at: displayLink.targetTimestamp) {
            hide()
            onIdle()
            return
        }
        guard state.isVisible else {
            hide()
            capture.setRate(.idle)
            return
        }
        capture.setRate(.engaged)
        guard let frame = capture.latestFrame else {
            hide()
            return
        }
        render(frame: frame, state: state)
    }

    private func render(frame: CapturedFrame, state: FoldState) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            abandon(String(localized: "could not create a Metal command buffer"))
            return
        }
        commandBuffer.label = "Mac Duo frame"
        if !overlay.isShown {
            overlay.prepareToShow()
            showGeneration += 1
            revealPending = true
        }
        // Acquire the drawable first: cached per-frame work must never go into a dropped command buffer.
        guard let drawable = overlay.metalLayer.nextDrawable() else {
            inFlight.signal()
            drawableFailures += 1
            if drawableFailures >= Self.drawableFailureLimit {
                abandon(String(localized: "the display stopped providing drawables"))
            }
            return
        }
        drawableFailures = 0

        guard pyramid.build(from: frame, commandBuffer: commandBuffer), let pyramidTexture = pyramid.texture else {
            inFlight.signal()
            abandon(String(localized: "could not allocate the blur pyramid"))
            return
        }
        let input = EffectInput(source: frame.texture, pyramid: pyramidTexture, blurInfo: pyramid.info, geometry: geometry)
        let frameChanged = frame.sequence != preparedSequence || effectChanged
        do {
            try effect.prepare(commandBuffer, input: input, frameChanged: frameChanged, state: state, parameters: effectParameters)
        } catch {
            inFlight.signal()
            abandon("\(type(of: effect).info.name): \(error)")
            return
        }
        preparedSequence = frame.sequence
        effectChanged = false

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            abandon(String(localized: "could not create a render encoder"))
            return
        }
        encoder.label = "Effect"
        effect.encode(encoder, input: input, state: state, parameters: effectParameters)
        encoder.endEncoding()

        if revealPending {
            revealPending = false
            let generation = showGeneration
            drawable.addPresentedHandler { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.showGeneration == generation else { return }
                    self.overlay.reveal()
                }
            }
        }
        commandBuffer.present(drawable)
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // Keeps the captured surface alive until the GPU has read it.
            withExtendedLifetime(frame) {}
            semaphore.signal()
            if buffer.status == .error {
                let message = buffer.error?.localizedDescription ?? String(localized: "unknown error")
                Task { @MainActor in self?.abandon(String(localized: "GPU error: \(message)")) }
            }
        }
        commandBuffer.commit()
    }

    /// Stops drawing and reports why. Drawing resumes on the next wake, which limits a permanent
    /// failure to one report per wake.
    private func abandon(_ reason: String) {
        stop()
        onFailure(reason)
    }
}
