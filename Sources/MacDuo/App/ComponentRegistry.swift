import MacDuoKit

/// Every motion model and effect the app knows. New components are registered here.
@MainActor
enum ComponentRegistry {
    static let motionModels: [any MotionModel.Type] = [
        OpticalReferenceMotion.self,
    ]

    static let effects: [any Effect.Type] = [
        OpticalGlassEffect.self,
    ]

    static let defaultMotionID = OpticalReferenceMotion.info.id
    static let defaultEffectID = OpticalGlassEffect.info.id

    // Explicit closures: `map(\.info)` over existential metatypes crashes the Swift 6.3 compiler.
    static var motionInfos: [ComponentInfo] { motionModels.map { $0.info } }
    static var effectInfos: [ComponentInfo] { effects.map { $0.info } }

    static var parameterSpecsByComponent: [String: [ParameterSpec]] {
        Dictionary(uniqueKeysWithValues: (motionInfos + effectInfos).map { ($0.id, $0.parameters) })
    }

    static func motionModel(id: String) -> (any MotionModel.Type)? {
        motionModels.first { $0.info.id == id }
    }

    static func effect(id: String) -> (any Effect.Type)? {
        effects.first { $0.info.id == id }
    }
}
