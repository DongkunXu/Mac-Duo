import AppKit
import CoreVideo
import MacDuoKit
import Metal

/// Offscreen checks of the rendering pipeline on synthetic images, run with `MacDuo --self-test`.
/// The sensor, capture and overlay are not touched.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--self-test") else { return }
        do {
            exit(try run() ? 0 : 1)
        } catch {
            print("SELF-TEST SETUP FAILED: \(error)")
            exit(2)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func run() throws -> Bool {
        let harness = try Harness()
        var results: [(name: String, passed: Bool, detail: String)] = []
        func record(_ name: String, _ body: () throws -> String) {
            do {
                results.append((name, true, try body()))
            } catch {
                results.append((name, false, "\(error)"))
            }
        }

        record("Blur pyramid calibration") { try harness.blurCalibration() }
        for type in ComponentRegistry.effects {
            let name = type.info.name
            record("\(name): identity at rest") { try harness.identity(type) }
            record("\(name): finite output across the fold range") { try harness.finiteness(type) }
            record("\(name): visible change mid-fold") { try harness.midFold(type) }
            record("\(name): GPU time at native size") { try harness.timing(type) }
        }

        for result in results {
            print("\(result.passed ? "PASS" : "FAIL")  \(result.name): \(result.detail)")
        }
        let failed = results.filter { !$0.passed }.count
        print(failed == 0 ? "ALL \(results.count) CHECKS PASSED" : "\(failed) OF \(results.count) CHECKS FAILED")
        return failed == 0
    }
}

@MainActor
private final class Harness {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let cache: CVMetalTextureCache
    let pyramid: BlurPyramid
    /// Physical size used for effect geometry: the real built-in panel when available.
    let millimeters: SIMD2<Float>
    let nativeSize: (width: Int, height: Int)
    private var sequence: UInt64 = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SelfTest.Failure(description: "no Metal device") }
        guard let queue = device.makeCommandQueue() else { throw SelfTest.Failure(description: "no command queue") }
        guard let library = device.makeDefaultLibrary() else { throw SelfTest.Failure(description: "no shader library") }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw SelfTest.Failure(description: "no texture cache")
        }
        self.device = device
        self.queue = queue
        self.library = library
        self.cache = cache
        pyramid = try BlurPyramid(device: device, library: library)

        if let screen = NSScreen.builtIn, let id = screen.displayID {
            let size = CGDisplayScreenSize(id)
            millimeters = SIMD2(Float(size.width), Float(size.height))
            nativeSize = (Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor))
        } else {
            // No built-in panel (for example in clamshell mode): use a 16-inch MacBook Pro panel.
            millimeters = SIMD2(345.6, 223.4)
            nativeSize = (3456, 2234)
        }
    }

    // MARK: Checks

    func blurCalibration() throws -> String {
        let width = 2048, height = 32
        let (frame, _) = try makeFrame(width: width, height: height) { x, _ in x < width / 2 ? (0, 0, 0) : (255, 255, 255) }
        let resources = EffectResources(device: device, library: library, pixelFormat: .bgra8Unorm_srgb)
        let pipeline = try FullscreenPipeline(resources: resources, fragment: "selfTestBlurFragment")
        var lines: [String] = []
        var worst = 0.0
        for sigma in [1.5, 3, 6, 12, 24, 48, 96, 192] as [Float] {
            let bytes = try render(frame: frame, width: width, height: height, format: .bgra8Unorm_srgb) { encoder, input in
                pipeline.draw(encoder, input: input, uniforms: sigma)
            }.bytes
            let row = height / 2
            let profile = (0..<width).map { x in Self.srgbToLinear(Double(bytes[(row * width + x) * 4 + 1]) / 255) }
            guard let x10 = Self.crossing(profile, level: 0.1), let x90 = Self.crossing(profile, level: 0.9) else {
                throw SelfTest.Failure(description: "σ \(sigma): edge profile has no 10–90% crossing")
            }
            let expected = 2.5631 * Double(sigma)
            let error = (x90 - x10) / expected - 1
            let tolerance = sigma < 2 ? 0.25 : 0.12
            if abs(error) > tolerance {
                throw SelfTest.Failure(description: String(format: "σ %.1f px: 10–90%% width %.2f px, expected %.2f (%+.1f%%)",
                                                            sigma, x90 - x10, expected, error * 100))
            }
            worst = max(worst, abs(error))
            lines.append(String(format: "σ%.0f %+.1f%%", sigma, error * 100))
        }
        return "edge width vs Gaussian: " + lines.joined(separator: ", ") + String(format: " (worst %.1f%%)", worst * 100)
    }

    func identity(_ type: any Effect.Type) throws -> String {
        let width = 640, height = 400
        let (frame, source) = try makeFrame(width: width, height: height, pixel: Self.pattern(width: width, height: height))
        let effect = try type.init(resources: EffectResources(device: device, library: library, pixelFormat: .bgra8Unorm_srgb))
        let state = FoldState(lidAngle: 95, referenceAngle: 95, isVisible: true)
        let output = try renderEffect(effect, frame: frame, width: width, height: height, state: state, format: .bgra8Unorm_srgb).bytes
        var maxDifference = 0
        var differing = 0
        for index in 0..<source.count {
            let difference = abs(Int(output[index]) - Int(source[index]))
            if difference > 0 { differing += 1 }
            maxDifference = max(maxDifference, difference)
        }
        guard maxDifference == 0 else {
            throw SelfTest.Failure(description: "\(differing) channel values differ, max difference \(maxDifference)")
        }
        return "\(width)×\(height) output identical to the desktop"
    }

    func finiteness(_ type: any Effect.Type) throws -> String {
        let width = 320, height = 200
        let (frame, _) = try makeFrame(width: width, height: height, pixel: Self.pattern(width: width, height: height))
        let effect = try type.init(resources: EffectResources(device: device, library: library, pixelFormat: .rgba16Float))
        var cases = 0
        for reference in [60.0, 95, 120] {
            for deviation in [-120.0, -90, -60, -30, -20, -5, -1, -0.01, 0, 1, 20, 45] where reference + deviation >= 0 {
                let state = FoldState(lidAngle: reference + deviation, referenceAngle: reference, isVisible: true)
                let halves = try renderEffect(effect, frame: frame, width: width, height: height, state: state, format: .rgba16Float).halves
                if let bad = halves.firstIndex(where: { !Float(Float16(bitPattern: $0)).isFinite }) {
                    throw SelfTest.Failure(description: "non-finite value at pixel \(bad / 4) for reference \(reference)°, deviation \(deviation)°")
                }
                cases += 1
            }
        }
        return "\(cases) fold states, every channel finite"
    }

    func midFold(_ type: any Effect.Type) throws -> String {
        let width = 640, height = 400
        let (frame, source) = try makeFrame(width: width, height: height, pixel: Self.pattern(width: width, height: height))
        let effect = try type.init(resources: EffectResources(device: device, library: library, pixelFormat: .bgra8Unorm_srgb))
        let state = FoldState(lidAngle: 65, referenceAngle: 95, isVisible: true)
        let output = try renderEffect(effect, frame: frame, width: width, height: height, state: state, format: .bgra8Unorm_srgb).bytes
        var sourceSum = 0, outputSum = 0, differenceSum = 0
        for index in stride(from: 0, to: source.count, by: 4) {
            for channel in 0..<3 {
                sourceSum += Int(source[index + channel])
                outputSum += Int(output[index + channel])
                differenceSum += abs(Int(output[index + channel]) - Int(source[index + channel]))
            }
        }
        let channels = Double(source.count / 4 * 3)
        let meanDifference = Double(differenceSum) / channels
        let brightness = Double(outputSum) / Double(max(sourceSum, 1))
        guard meanDifference > 1 else { throw SelfTest.Failure(description: "output barely differs from the desktop (mean Δ \(meanDifference))") }
        guard brightness > 0.05 else { throw SelfTest.Failure(description: String(format: "output nearly black (%.1f%% of desktop brightness)", brightness * 100)) }
        return String(format: "mean channel change %.1f, brightness %.0f%% of desktop", meanDifference, brightness * 100)
    }

    func timing(_ type: any Effect.Type) throws -> String {
        let (width, height) = nativeSize
        let (frame, _) = try makeFrame(width: width, height: height, pixel: Self.pattern(width: width, height: height))
        let effect = try type.init(resources: EffectResources(device: device, library: library, pixelFormat: .bgra8Unorm_srgb))
        let state = FoldState(lidAngle: 65, referenceAngle: 95, isVisible: true)
        // The first frame includes the pyramid build; later frames reuse it like the live loop.
        let first = try renderEffect(effect, frame: frame, width: width, height: height, state: state, format: .bgra8Unorm_srgb).gpuTime
        var steady: [Double] = []
        for _ in 0..<5 {
            steady.append(try renderEffect(effect, frame: frame, width: width, height: height, state: state, format: .bgra8Unorm_srgb).gpuTime)
        }
        return String(format: "%d×%d: %.2f ms with pyramid build, %.2f ms per frame after", width, height,
                      first * 1000, (steady.sorted()[steady.count / 2]) * 1000)
    }

    // MARK: Rendering

    private func renderEffect(_ effect: any Effect, frame: CapturedFrame, width: Int, height: Int, state: FoldState,
                              format: MTLPixelFormat) throws -> (bytes: [UInt8], halves: [UInt16], gpuTime: Double) {
        let parameters = ParameterValues()
        return try render(frame: frame, width: width, height: height, format: format, prepare: { commandBuffer, input in
            try effect.prepare(commandBuffer, input: input, frameChanged: true, state: state, parameters: parameters)
        }) { encoder, input in
            effect.encode(encoder, input: input, state: state, parameters: parameters)
        }
    }

    private func render(frame: CapturedFrame, width: Int, height: Int, format: MTLPixelFormat,
                        prepare: ((MTLCommandBuffer, EffectInput) throws -> Void)? = nil,
                        draw: (MTLRenderCommandEncoder, EffectInput) -> Void) throws -> (bytes: [UInt8], halves: [UInt16], gpuTime: Double) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw SelfTest.Failure(description: "could not allocate the render target")
        }
        guard pyramid.build(from: frame, commandBuffer: commandBuffer), let pyramidTexture = pyramid.texture else {
            throw SelfTest.Failure(description: "could not build the pyramid")
        }
        let input = EffectInput(
            source: frame.texture, pyramid: pyramidTexture, blurInfo: pyramid.info,
            geometry: DisplayGeometry(pixelSize: SIMD2(Float(width), Float(height)), millimeters: millimeters))
        try prepare?(commandBuffer, input)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw SelfTest.Failure(description: "could not create a render encoder")
        }
        draw(encoder, input)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.status == .error {
            throw SelfTest.Failure(description: "GPU error: \(commandBuffer.error?.localizedDescription ?? "unknown")")
        }
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        let gpuTime = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        if format == .rgba16Float {
            var halves = [UInt16](repeating: 0, count: width * height * 4)
            target.getBytes(&halves, bytesPerRow: width * 8, from: region, mipmapLevel: 0)
            return ([], halves, gpuTime)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: region, mipmapLevel: 0)
        return (bytes, [], gpuTime)
    }

    /// A Metal-compatible BGRA pixel buffer filled by `pixel` (returns r, g, b), wrapped exactly as
    /// live capture does. Also returns the tightly packed BGRA bytes for comparisons.
    private func makeFrame(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> (CapturedFrame, [UInt8]) {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            throw SelfTest.Failure(description: "could not create a pixel buffer")
        }
        var packed = [UInt8](repeating: 0, count: width * height * 4)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw SelfTest.Failure(description: "pixel buffer has no memory") }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let memory = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let offset = y * rowBytes + x * 4
                memory[offset] = b
                memory[offset + 1] = g
                memory[offset + 2] = r
                memory[offset + 3] = 255
                let packedOffset = (y * width + x) * 4
                packed[packedOffset] = b
                packed[packedOffset + 1] = g
                packed[packedOffset + 2] = r
                packed[packedOffset + 3] = 255
            }
        }
        sequence += 1
        guard let frame = CapturedFrame.make(pixelBuffer: pixelBuffer, cache: cache, sequence: sequence) else {
            throw SelfTest.Failure(description: "could not wrap the pixel buffer")
        }
        return (frame, packed)
    }

    // MARK: Helpers

    /// Gradients plus an 8-px checkerboard: every pixel distinct enough to expose resampling.
    private static func pattern(width: Int, height: Int) -> (Int, Int) -> (UInt8, UInt8, UInt8) {
        { x, y in
            (UInt8(x * 255 / max(width - 1, 1)),
             UInt8(y * 255 / max(height - 1, 1)),
             (x / 8 + y / 8) % 2 == 0 ? 230 : 25)
        }
    }

    private static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// First position where a rising profile reaches `level`, linearly interpolated.
    private static func crossing(_ profile: [Double], level: Double) -> Double? {
        for index in 1..<profile.count where profile[index - 1] < level && profile[index] >= level {
            let fraction = (level - profile[index - 1]) / (profile[index] - profile[index - 1])
            return Double(index - 1) + fraction
        }
        return nil
    }
}
