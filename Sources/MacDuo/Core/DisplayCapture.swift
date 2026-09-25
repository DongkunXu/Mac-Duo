import AppKit
import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit
import Synchronization

/// One captured desktop frame as a GPU texture aliasing ScreenCaptureKit's IOSurface. Holding it
/// keeps the pixel buffer and the CoreVideo texture alive. Renderers retain it until their command
/// buffer completes.
struct CapturedFrame: @unchecked Sendable {
    // @unchecked: every stored property is immutable.
    let sequence: UInt64
    /// `.bgra8Unorm_srgb` view; sampling returns linear light.
    let texture: MTLTexture
    let width: Int
    let height: Int
    private let pixelBuffer: CVPixelBuffer
    private let textureRef: CVMetalTexture

    fileprivate init(sequence: UInt64, texture: MTLTexture, pixelBuffer: CVPixelBuffer, textureRef: CVMetalTexture) {
        self.sequence = sequence
        self.texture = texture
        self.width = texture.width
        self.height = texture.height
        self.pixelBuffer = pixelBuffer
        self.textureRef = textureRef
    }
}

extension CapturedFrame {
    /// Wraps a Metal-compatible BGRA pixel buffer without copying.
    static func make(pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache, sequence: UInt64) -> CapturedFrame? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var textureRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm_srgb, width, height, 0, &textureRef)
        guard status == kCVReturnSuccess, let textureRef, let texture = CVMetalTextureGetTexture(textureRef) else { return nil }
        return CapturedFrame(sequence: sequence, texture: texture, pixelBuffer: pixelBuffer, textureRef: textureRef)
    }
}

enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)
    case ownApplicationNotListed
    case textureCacheUnavailable(CVReturn)
    case system(Error)

    var description: String {
        switch self {
        case .permissionDenied: String(localized: "Screen Recording permission is not granted.")
        case .displayNotFound(let id): String(localized: "Display \(id) is not available for capture.")
        case .ownApplicationNotListed: String(localized: "Could not exclude Mac Duo from its own capture.")
        case .textureCacheUnavailable(let code): String(localized: "Could not create the Metal texture cache (\(code)).")
        case .system(let error): error.localizedDescription
        }
    }
}

/// Streams the built-in display into Metal textures, excluding this app's own windows. It runs only
/// while the engine is awake. The content filter is cached: fetching the shareable content takes
/// about 50 ms, starting a stream with a ready filter about 25 ms.
@MainActor
final class DisplayCapture {
    enum Rate: Equatable {
        /// 5 fps, keeping a recent frame ready.
        case idle
        /// 60 fps while the overlay is on screen.
        case engaged
    }

    private struct CachedFilter {
        let displayID: CGDirectDisplayID
        let filter: SCContentFilter
    }

    private let receiver: FrameReceiver
    private var cachedFilter: CachedFilter?
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private(set) var rate: Rate = .idle
    private var rateUpdate: Task<Void, Never>?
    private let onFailure: @MainActor (CaptureError) -> Void
    /// Incremented by every start and stop; a start that finds it changed abandons its stream.
    private var generation = 0

    static let idleInterval = CMTime(value: 1, timescale: 5)
    static let engagedInterval = CMTime(value: 1, timescale: 60)
    static let colorSpace = CGColorSpace.displayP3

    init(device: MTLDevice, onFailure: @escaping @MainActor (CaptureError) -> Void) throws(CaptureError) {
        receiver = try FrameReceiver(device: device)
        self.onFailure = onFailure
    }

    /// Newest complete frame, or nil before the first one arrives.
    var latestFrame: CapturedFrame? { receiver.latest }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once; afterwards the user must enable access in System Settings.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Starts streaming `displayID`. Any earlier frame stays available until the new stream delivers
    /// one. Returns without starting if another start or stop supersedes this call.
    func start(displayID: CGDirectDisplayID) async throws(CaptureError) {
        await stop(keepingLastFrame: true)
        generation += 1
        let token = generation
        guard Self.hasPermission else { throw .permissionDenied }

        let filter: SCContentFilter
        if let cached = cachedFilter, cached.displayID == displayID {
            filter = cached.filter
        } else {
            let content: SCShareableContent
            do {
                // Include off-screen windows: the overlay is ordered out now, and the app must be
                // listed to be excluded from its own capture.
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                throw .system(error)
            }
            guard token == generation else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw .displayNotFound(displayID)
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            guard let ownApp = content.applications.first(where: { $0.processID == pid }) else {
                throw .ownApplicationNotListed
            }
            filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
            cachedFilter = CachedFilter(displayID: displayID, filter: filter)
        }

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = Self.colorSpace
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 5
        config.minimumFrameInterval = rate == .engaged ? Self.engagedInterval : Self.idleInterval

        let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
        let streamID = ObjectIdentifier(stream)
        receiver.onStop = { [weak self] error in
            Task { @MainActor in self?.streamStopped(error, streamID: streamID) }
        }
        do {
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await stream.startCapture()
        } catch {
            // The filter may be stale (for example after a display change); rebuild it next time.
            cachedFilter = nil
            throw .system(error)
        }
        guard token == generation else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        self.configuration = config
        applyRate()
    }

    /// Stops streaming. With `keepingLastFrame` the newest frame stays available, which is used
    /// across system sleep.
    func stop(keepingLastFrame: Bool = false) async {
        generation += 1
        rateUpdate?.cancel()
        rateUpdate = nil
        if !keepingLastFrame { receiver.clear() }
        guard let stream else { return }
        self.stream = nil
        self.configuration = nil
        // The stream may already have stopped on its own; there is nothing to recover then.
        try? await stream.stopCapture()
    }

    /// Drops any retained desktop frame without touching the stream.
    func discardFrames() {
        receiver.clear()
    }

    /// Call when the display configuration changes.
    func invalidateFilter() {
        cachedFilter = nil
    }

    func setRate(_ newRate: Rate) {
        guard newRate != rate else { return }
        rate = newRate
        applyRate()
    }

    /// Brings the running stream to the requested rate. Also called right after a start, because the
    /// rate usually changes while the stream is starting.
    private func applyRate() {
        guard let stream, let configuration else { return }
        let interval = rate == .engaged ? Self.engagedInterval : Self.idleInterval
        guard configuration.minimumFrameInterval != interval else { return }
        configuration.minimumFrameInterval = interval
        let previous = rateUpdate
        rateUpdate = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await stream.updateConfiguration(configuration)
            } catch {
                // A stream stopped or replaced meanwhile refuses the update; that is expected.
                guard let self, self.stream === stream else { return }
                onFailure(.system(error))
            }
        }
    }

    private func streamStopped(_ error: Error, streamID: ObjectIdentifier) {
        guard let stream, ObjectIdentifier(stream) == streamID else { return }
        self.stream = nil
        configuration = nil
        cachedFilter = nil
        generation += 1
        receiver.clear()
        onFailure(.system(error))
    }
}

/// Receives sample buffers on its own queue and publishes the newest complete frame.
private final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked: `textureCache` and `sequence` are only touched on `queue`; the rest is behind locks.
    let queue = DispatchQueue(label: "MacDuo.DisplayCapture", qos: .userInteractive)
    private let textureCache: CVMetalTextureCache
    private var sequence: UInt64 = 0
    private let frame = Mutex<CapturedFrame?>(nil)
    private let stopHandler = Mutex<(@Sendable (Error) -> Void)?>(nil)

    init(device: MTLDevice) throws(CaptureError) {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw .textureCacheUnavailable(status) }
        textureCache = cache
    }

    var latest: CapturedFrame? { frame.withLock { $0 } }

    var onStop: (@Sendable (Error) -> Void)? {
        get { stopHandler.withLock { $0 } }
        set { stopHandler.withLock { $0 = newValue } }
    }

    func clear() {
        frame.withLock { $0 = nil }
        queue.async { [self] in CVMetalTextureCacheFlush(textureCache, 0) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer,
              let captured = CapturedFrame.make(pixelBuffer: pixelBuffer, cache: textureCache, sequence: sequence + 1) else { return }
        sequence += 1
        frame.withLock { $0 = captured }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}
