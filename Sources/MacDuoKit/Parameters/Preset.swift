import Foundation

/// A named combination of one motion model and one effect with their parameter values.
public struct Preset: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var motionID: String
    public var effectID: String
    public var motionParameters: ParameterValues
    public var effectParameters: ParameterValues

    public init(id: UUID = UUID(), name: String, motionID: String, effectID: String,
                motionParameters: ParameterValues = ParameterValues(), effectParameters: ParameterValues = ParameterValues()) {
        self.id = id
        self.name = name
        self.motionID = motionID
        self.effectID = effectID
        self.motionParameters = motionParameters
        self.effectParameters = effectParameters
    }
}

/// The live configuration: the active components and the tuning of every component. Each component
/// keeps its values when you switch away and back.
public struct Selection: Codable, Sendable, Equatable {
    public var motionID: String
    public var effectID: String
    public var parametersByComponent: [String: ParameterValues]

    public init(motionID: String, effectID: String, parametersByComponent: [String: ParameterValues] = [:]) {
        self.motionID = motionID
        self.effectID = effectID
        self.parametersByComponent = parametersByComponent
    }

    public func parameters(for componentID: String) -> ParameterValues {
        parametersByComponent[componentID] ?? ParameterValues()
    }

    public mutating func setParameters(_ values: ParameterValues, for componentID: String) {
        parametersByComponent[componentID] = values
    }

    /// Drops stored values of components and parameters that no longer exist.
    public mutating func prune(keeping specsByComponent: [String: [ParameterSpec]]) {
        parametersByComponent = parametersByComponent.reduce(into: [:]) { result, entry in
            guard let specs = specsByComponent[entry.key] else { return }
            result[entry.key] = entry.value.restricted(to: specs)
        }
    }

    public var motionParameters: ParameterValues { parameters(for: motionID) }
    public var effectParameters: ParameterValues { parameters(for: effectID) }

    public mutating func apply(_ preset: Preset) {
        motionID = preset.motionID
        effectID = preset.effectID
        parametersByComponent[preset.motionID] = preset.motionParameters
        parametersByComponent[preset.effectID] = preset.effectParameters
    }

    public func snapshot(named name: String) -> Preset {
        Preset(name: name, motionID: motionID, effectID: effectID,
               motionParameters: motionParameters, effectParameters: effectParameters)
    }
}
