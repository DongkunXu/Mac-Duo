import AppKit
import MacDuoKit
import Metal

enum EngineError: Error, CustomStringConvertible {
    case metal(String)
    case render(RenderError)
    case capture(CaptureError)
    case noBuiltInDisplay
    case unknownDisplaySize
    case unknownComponent(String)

    var description: String {
        switch self {
        case .metal(let reason): String(localized: "Metal: \(reason)")
        case .render(let error): String(localized: "Rendering: \(error.description)")
        case .capture(let error): String(localized: "Capture: \(error.description)")
        case .noBuiltInDisplay: String(localized: "The built-in display is not active.")
        case .unknownDisplaySize: String(localized: "The built-in display did not report its physical size.")
        case .unknownComponent(let id): String(localized: "Unknown component “\(id)”.")
        }
    }
}

/// Owns the long-lived runtime objects: Metal, sensor, capture, and the overlay and render host for
/// the current built-in display.
@MainActor
final class Engine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let resources: EffectResources
    let pyramid: BlurPyramid
    let sensor: LidSensor
    let arming: ArmingWatcher
    let capture: DisplayCapture
    private var effects: [String: any Effect] = [:]
    private(set) var overlay: OverlayWindow?
    private(set) var host: RenderHost?

    init(onSensorStatus: @escaping @MainActor @Sendable (LidSensor.Status) -> Void,
         onCaptureFailure: @escaping @MainActor (CaptureError) -> Void,
         onArm: @escaping @MainActor @Sendable () -> Void) throws(EngineError) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw .metal(String(localized: "no Metal device")) }
        guard let queue = device.makeCommandQueue() else { throw .metal(String(localized: "could not create a command queue")) }
        guard let library = device.makeDefaultLibrary() else { throw .metal(String(localized: "the app’s shader library is missing")) }
        self.device = device
        self.queue = queue
        resources = EffectResources(device: device, library: library, pixelFormat: .bgra8Unorm_srgb)
        do {
            pyramid = try BlurPyramid(device: device, library: library)
        } catch {
            throw .render(error)
        }
        do {
            capture = try DisplayCapture(device: device, onFailure: onCaptureFailure)
        } catch {
            throw .capture(error)
        }
        let arming = ArmingWatcher(onArm: onArm)
        self.arming = arming
        sensor = LidSensor(onSample: { arming.observe($0) }, onStatusChange: onSensorStatus)
    }

    func effect(id: String) throws(EngineError) -> any Effect {
        if let cached = effects[id] { return cached }
        guard let type = ComponentRegistry.effect(id: id) else { throw .unknownComponent(id) }
        do {
            let created = try type.init(resources: resources)
            effects[id] = created
            return created
        } catch {
            throw .render(error)
        }
    }

    var overlayMatchesDisplay: Bool {
        guard let overlay, let screen = NSScreen.builtIn else { return false }
        return overlay.matches(screen)
    }

    func prepareDisplay(selection: Selection, onRenderFailure: @escaping (String) -> Void,
                        onIdle: @escaping () -> Void) throws(EngineError) {
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { throw .noBuiltInDisplay }
        if host != nil, overlay?.matches(screen) == true { return }
        teardownDisplay()

        let physical = CGDisplayScreenSize(displayID)
        guard physical.width > 0, physical.height > 0 else { throw .unknownDisplaySize }
        guard let motionType = ComponentRegistry.motionModel(id: selection.motionID) else {
            throw .unknownComponent(selection.motionID)
        }
        let effect = try effect(id: selection.effectID)

        let overlay = OverlayWindow(screen: screen, device: device)
        let pixels = overlay.drawableSize
        let geometry = DisplayGeometry(
            pixelSize: SIMD2(Float(pixels.width), Float(pixels.height)),
            millimeters: SIMD2(Float(physical.width), Float(physical.height)))
        host = RenderHost(
            resources: resources, queue: queue, pyramid: pyramid, sensor: sensor, capture: capture,
            overlay: overlay, geometry: geometry,
            motion: motionType.init(), motionParameters: selection.motionParameters,
            effect: effect, effectParameters: selection.effectParameters,
            onFailure: onRenderFailure, onIdle: onIdle)
        self.overlay = overlay
    }

    func teardownDisplay() {
        host?.stop()
        host = nil
        overlay?.close()
        overlay = nil
        pyramid.release()
    }
}
