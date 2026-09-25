import MacDuoKit
import Metal

struct DisplayGeometry: Equatable {
    let pixelSize: SIMD2<Float>
    /// Active area in millimetres, from `CGDisplayScreenSize`.
    let millimeters: SIMD2<Float>
}

struct EffectInput {
    /// Captured desktop; sampling returns linear light.
    let source: MTLTexture
    let pyramid: MTLTexture
    let blurInfo: BlurInfo
    let geometry: DisplayGeometry
}

struct EffectResources {
    let device: MTLDevice
    let library: MTLLibrary
    let pixelFormat: MTLPixelFormat
}

/// Draws one frame from the captured desktop and the fold state. Per frame the host calls `prepare`
/// for optional extra GPU work, then `encode` inside a render pass on the drawable. Parameters are
/// read every frame and edits apply immediately.
@MainActor
protocol Effect: AnyObject {
    static var info: ComponentInfo { get }
    init(resources: EffectResources) throws(RenderError)

    /// `frameChanged` is true when `input.source` is a frame this effect has not been prepared with.
    /// Throwing removes the overlay and reports the error. Draw either the correct image or nothing.
    func prepare(_ commandBuffer: MTLCommandBuffer, input: EffectInput, frameChanged: Bool,
                 state: FoldState, parameters: ParameterValues) throws(RenderError)

    func encode(_ encoder: MTLRenderCommandEncoder, input: EffectInput, state: FoldState, parameters: ParameterValues)
}

extension Effect {
    func prepare(_ commandBuffer: MTLCommandBuffer, input: EffectInput, frameChanged: Bool,
                 state: FoldState, parameters: ParameterValues) throws(RenderError) {}
}

/// A fullscreen-triangle pipeline with the standard effect bindings:
/// texture 0 = source, texture 1 = pyramid, textures 2... = `extraTextures`,
/// fragment buffer 0 = `BlurInfo`, buffer 1 = effect uniforms.
@MainActor
final class FullscreenPipeline {
    private let state: MTLRenderPipelineState

    init(resources: EffectResources, fragment: String) throws(RenderError) {
        guard let vertexFunction = resources.library.makeFunction(name: "fullscreenVertex") else {
            throw .missingFunction("fullscreenVertex")
        }
        guard let fragmentFunction = resources.library.makeFunction(name: fragment) else {
            throw .missingFunction(fragment)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = fragment
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = resources.pixelFormat
        do {
            state = try resources.device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipeline(fragment, error)
        }
    }

    /// `Uniforms` must be a C struct (or scalar) whose layout matches the shader's.
    func draw<Uniforms: BitwiseCopyable>(_ encoder: MTLRenderCommandEncoder, input: EffectInput, uniforms: Uniforms,
                                         extraTextures: [MTLTexture] = []) {
        var info = input.blurInfo
        var values = uniforms
        encoder.setRenderPipelineState(state)
        encoder.setFragmentTexture(input.source, index: 0)
        encoder.setFragmentTexture(input.pyramid, index: 1)
        for (offset, texture) in extraTextures.enumerated() {
            encoder.setFragmentTexture(texture, index: 2 + offset)
        }
        encoder.setFragmentBytes(&info, length: MemoryLayout<BlurInfo>.stride, index: 0)
        encoder.setFragmentBytes(&values, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
