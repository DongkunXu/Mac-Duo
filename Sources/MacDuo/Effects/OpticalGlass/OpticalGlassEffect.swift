import MacDuoKit
import Metal

/// The desktop pinned to a plane at the reference angle, seen through the lid as frosted glass.
/// Geometry is an exact ray–plane intersection in millimetres; blur and darkening grow with the
/// glass-to-plane distance along each line of sight.
///
/// The optical idea (fixed plane, fixed eye, 1:1 physical tilt, blur proportional to the gap)
/// follows askmaddyy/FrostFold (MIT); this implementation is independent.
@MainActor
final class OpticalGlassEffect: Effect {
    static let eyeDistance = ParameterSpec(
        id: "eyeDistance", name: String(localized: "Eye distance"), range: 250...1200, step: 10, default: 500, unit: "mm",
        detail: String(localized: "Distance from the viewer’s eye to the screen."))
    static let eyeLift = ParameterSpec(
        id: "eyeLift", name: String(localized: "Eye height above screen centre"), range: -200...300, step: 5, default: 60, unit: "mm")
    static let eyeLateral = ParameterSpec(
        id: "eyeLateral", name: String(localized: "Eye offset sideways"), range: -300...300, step: 5, default: 0, unit: "mm")
    static let hingeOffset = ParameterSpec(
        id: "hingeOffset", name: String(localized: "Hinge to picture edge"), range: 0...40, step: 0.5, default: 10, unit: "mm",
        detail: String(localized: "Distance from the hinge axis to the bottom edge of the lit panel."))
    static let tiltScale = ParameterSpec(
        id: "tiltScale", name: String(localized: "Tilt scale"), range: 0...1.5, step: 0.01, default: 1,
        detail: String(localized: "1 follows the physical lid exactly; smaller values soften the virtual rotation."))
    static let blurPerMM = ParameterSpec(
        id: "blurPerMM", name: String(localized: "Frost"), range: 0...0.4, step: 0.005, default: 0.12,
        detail: String(localized: "Blur per millimetre of distance between glass and content."))
    static let baseGap = ParameterSpec(
        id: "baseGap", name: String(localized: "Base separation"), range: 0...40, step: 0.5, default: 0, unit: "mm",
        detail: String(localized: "Extra distance added everywhere once folding starts, softening the hinge edge too. 0 keeps the hinge region sharp."))
    static let maxSigma = ParameterSpec(
        id: "maxSigma", name: String(localized: "Maximum blur"), range: 1...80, step: 0.5, default: 30, unit: "mm")
    static let darkening = ParameterSpec(
        id: "darkening", name: String(localized: "Darkening"), range: 0...0.02, step: 0.0005, default: 0.004, unit: "/mm")
    static let edge = ParameterSpec.choice(
        id: "edge", name: String(localized: "Outside the picture"),
        options: [String(localized: "Fade to black"), String(localized: "Stretch edge")], default: 0)

    static let info = ComponentInfo(
        id: "optical-glass",
        name: String(localized: "Optical glass"),
        summary: String(localized: "Exact line-of-sight projection onto the pinned content plane; frost grows with the gap."),
        parameters: [eyeDistance, eyeLift, eyeLateral, hingeOffset, tiltScale, blurPerMM, baseGap, maxSigma,
                     darkening, edge])

    private let pipeline: FullscreenPipeline

    init(resources: EffectResources) throws(RenderError) {
        pipeline = try FullscreenPipeline(resources: resources, fragment: "opticalGlassFragment")
    }

    func encode(_ encoder: MTLRenderCommandEncoder, input: EffectInput, state: FoldState, parameters p: ParameterValues) {
        let delta = state.deviation * .pi / 180 * p[Self.tiltScale]
        let uniforms = OpticalGlassUniforms(
            outputSize: input.geometry.pixelSize,
            screenMM: input.geometry.millimeters,
            hingeOffsetMM: Float(p[Self.hingeOffset]),
            eyeDistanceMM: Float(p[Self.eyeDistance]),
            eyeLiftMM: Float(p[Self.eyeLift]),
            eyeLateralMM: Float(p[Self.eyeLateral]),
            deltaRadians: Float(delta),
            blurPerMM: Float(p[Self.blurPerMM]),
            baseGapMM: Float(p[Self.baseGap]),
            maxSigmaMM: Float(p[Self.maxSigma]),
            darkeningPerMM: Float(p[Self.darkening]),
            edgeBlack: p.index(Self.edge) == 0 ? 1 : 0)
        pipeline.draw(encoder, input: input, uniforms: uniforms)
    }
}
