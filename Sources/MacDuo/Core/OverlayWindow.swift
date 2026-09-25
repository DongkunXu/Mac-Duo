import AppKit
import Metal
import QuartzCore

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool {
        displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    /// The MacBook's internal display, if it is currently active.
    static var builtIn: NSScreen? {
        screens.first(where: \.isBuiltIn)
    }
}

/// A borderless, click-through panel covering one screen above every window on every Space, drawn
/// through a CAMetalLayer.
///
/// While idle the overlay can be parked: the panel shrinks and its layer is replaced by a tiny one.
/// A CAMetalLayer keeps its drawable pool (about 100 MB at native size) for its whole lifetime;
/// replacing the layer is what frees it.
@MainActor
final class OverlayWindow {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let frame: NSRect
    let scale: CGFloat
    private(set) var metalLayer: CAMetalLayer
    private let device: MTLDevice
    private let view: NSView
    private let panel: NSPanel
    private(set) var isShown = false

    private static let parkedSize = CGSize(width: 16, height: 16)

    init(screen: NSScreen, device: MTLDevice) {
        guard let displayID = screen.displayID else {
            preconditionFailure("NSScreen without a display ID")
        }
        self.screen = screen
        self.displayID = displayID
        self.frame = screen.frame
        self.scale = screen.backingScaleFactor
        self.device = device

        metalLayer = Self.makeLayer(device: device, scale: screen.backingScaleFactor, size: screen.frame.size)
        view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.layer = metalLayer
        view.wantsLayer = true

        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
    }

    var drawableSize: CGSize {
        CGSize(width: (frame.size.width * scale).rounded(), height: (frame.size.height * scale).rounded())
    }

    func matches(_ screen: NSScreen) -> Bool {
        screen.displayID == displayID && screen.frame == frame && screen.backingScaleFactor == scale
    }

    /// Orders the panel in transparent. `reveal()` follows once a frame has been presented, which
    /// keeps an empty or stale layer off the screen.
    func prepareToShow() {
        guard !isShown else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isShown = true
    }

    func reveal() {
        guard isShown else { return }
        panel.alphaValue = 1
    }

    func hide() {
        guard isShown else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
        isShown = false
    }

    /// Frees the layer's drawable pool and the panel's backing store.
    func park() {
        guard !isShown else { return }
        panel.setFrame(NSRect(origin: frame.origin, size: Self.parkedSize), display: false)
        view.frame = NSRect(origin: .zero, size: Self.parkedSize)
        replaceLayer(size: Self.parkedSize)
    }

    func unpark() {
        guard metalLayer.drawableSize != drawableSize else { return }
        panel.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
        replaceLayer(size: frame.size)
    }

    func close() {
        hide()
        panel.close()
    }

    private func replaceLayer(size: CGSize) {
        metalLayer = Self.makeLayer(device: device, scale: scale, size: size)
        view.layer = metalLayer
        view.wantsLayer = true
    }

    private static func makeLayer(device: MTLDevice, scale: CGFloat, size: CGSize) -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.colorspace = CGColorSpace(name: DisplayCapture.colorSpace)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.allowsNextDrawableTimeout = true
        layer.contentsScale = scale
        layer.frame = CGRect(origin: .zero, size: size)
        layer.drawableSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        return layer
    }
}
