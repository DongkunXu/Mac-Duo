import Foundation

/// Declares one tunable parameter; the settings UI generates its control from this.
public struct ParameterSpec: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A value within `range`; a `step` of 0 means unstepped.
        case continuous(range: ClosedRange<Double>, step: Double)
        /// Stored as the index of the selected option.
        case choice([String])
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let defaultValue: Double
    public let unit: String?
    public let detail: String?

    public init(id: String, name: String, range: ClosedRange<Double>, step: Double = 0,
                default defaultValue: Double, unit: String? = nil, detail: String? = nil) {
        precondition(range.contains(defaultValue), "default of \(id) outside its range")
        precondition(step >= 0, "step of \(id) must not be negative")
        self.init(id: id, name: name, kind: .continuous(range: range, step: step),
                  defaultValue: defaultValue, unit: unit, detail: detail)
    }

    public static func choice(id: String, name: String, options: [String], default index: Int, detail: String? = nil) -> ParameterSpec {
        precondition(options.indices.contains(index), "default of \(id) outside its options")
        return ParameterSpec(id: id, name: name, kind: .choice(options), defaultValue: Double(index), unit: nil, detail: detail)
    }

    private init(id: String, name: String, kind: Kind, defaultValue: Double, unit: String?, detail: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.unit = unit
        self.detail = detail
    }

    /// Brings an arbitrary stored value into this parameter's domain.
    public func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        switch kind {
        case .continuous(let range, let step):
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            guard step > 0 else { return clamped }
            let stepped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
            return min(stepped, range.upperBound)
        case .choice(let options):
            return Double(min(max(Int(value.rounded()), 0), options.count - 1))
        }
    }
}

/// Stored values keyed by `ParameterSpec.id`. Missing or out-of-domain values read back sanitized.
public struct ParameterValues: Sendable, Codable, Equatable {
    private var storage: [String: Double]

    public init(_ storage: [String: Double] = [:]) {
        self.storage = storage
    }

    public subscript(spec: ParameterSpec) -> Double {
        get { storage[spec.id].map(spec.sanitize) ?? spec.defaultValue }
        set { storage[spec.id] = spec.sanitize(newValue) }
    }

    public func index(_ spec: ParameterSpec) -> Int { Int(self[spec]) }

    /// Keeps only values belonging to `specs`, sanitized.
    public func restricted(to specs: [ParameterSpec]) -> ParameterValues {
        var result = ParameterValues()
        for spec in specs where storage[spec.id] != nil {
            result[spec] = self[spec]
        }
        return result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }

    public init(from decoder: Decoder) throws {
        storage = try decoder.singleValueContainer().decode([String: Double].self)
    }
}
