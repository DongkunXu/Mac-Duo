import Metal

enum RenderError: Error, CustomStringConvertible {
    case missingFunction(String)
    case pipeline(String, Error)

    var description: String {
        switch self {
        case .missingFunction(let name): String(localized: "shader function “\(name)” is missing")
        case .pipeline(let name, let error): String(localized: "pipeline “\(name)” failed: \(error.localizedDescription)")
        }
    }
}

/// Half-resolution mip chain of the captured desktop, rebuilt only when a new frame arrives.
/// Shaders sample it through `mdBlurSample` (Common.h), which knows the variance of every level.
@MainActor
final class BlurPyramid {
    static let maximumLevels = 10

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private(set) var texture: MTLTexture?
    private var levelViews: [MTLTexture] = []
    private var sourceWidth = 0
    private var sourceHeight = 0
    private(set) var builtSequence: UInt64?

    init(device: MTLDevice, library: MTLLibrary) throws(RenderError) {
        guard let function = library.makeFunction(name: "pyramidDownsample") else {
            throw .missingFunction("pyramidDownsample")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw .pipeline("pyramidDownsample", error)
        }
        self.device = device
    }

    var info: BlurInfo {
        guard let texture else {
            return BlurInfo(sourceSize: .zero, pyramidSize: .zero, levelCount: 0, padding: 0)
        }
        return BlurInfo(
            sourceSize: SIMD2(Float(sourceWidth), Float(sourceHeight)),
            pyramidSize: SIMD2(Float(texture.width), Float(texture.height)),
            levelCount: Float(texture.mipmapLevelCount),
            padding: 0)
    }

    /// Encodes the rebuild for `frame` unless it is already built; false if allocation failed.
    func build(from frame: CapturedFrame, commandBuffer: MTLCommandBuffer) -> Bool {
        guard frame.sequence != builtSequence else { return true }
        guard prepareTexture(width: frame.width, height: frame.height),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "Blur pyramid"
        encoder.setComputePipelineState(pipeline)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        for (level, destination) in levelViews.enumerated() {
            let source = level == 0 ? frame.texture : levelViews[level - 1]
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                    threadsPerThreadgroup: threads)
        }
        encoder.endEncoding()
        builtSequence = frame.sequence
        return true
    }

    /// Frees the pyramid texture (about 22 MB at 3600×2338); in-flight command buffers keep their own reference.
    func release() {
        texture = nil
        levelViews = []
        sourceWidth = 0
        sourceHeight = 0
        builtSequence = nil
    }

    private func prepareTexture(width: Int, height: Int) -> Bool {
        if texture != nil, width == sourceWidth, height == sourceHeight { return true }
        let baseWidth = max((width + 1) / 2, 1)
        let baseHeight = max((height + 1) / 2, 1)
        let fullChain = Int(floor(log2(Double(max(baseWidth, baseHeight))))) + 1
        let levels = min(fullChain, Self.maximumLevels)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: baseWidth, height: baseHeight, mipmapped: true)
        descriptor.mipmapLevelCount = levels
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.storageMode = .private
        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            texture = nil
            levelViews = []
            return false
        }
        newTexture.label = "Blur pyramid"
        var views: [MTLTexture] = []
        for level in 0..<levels {
            guard let view = newTexture.makeTextureView(
                pixelFormat: .rgba16Float, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1) else {
                texture = nil
                levelViews = []
                return false
            }
            views.append(view)
        }
        texture = newTexture
        levelViews = views
        sourceWidth = width
        sourceHeight = height
        builtSequence = nil
        return true
    }
}
