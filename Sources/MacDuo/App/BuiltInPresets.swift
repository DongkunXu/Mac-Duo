import Foundation
import MacDuoKit

/// Presets shipped with the app; their ids are fixed.
@MainActor
enum BuiltInPresets {
    static let all: [Preset] = [
        Preset(
            id: fixedID("00000000-0000-0000-0000-000000000001"),
            name: String(localized: "Default"),
            motionID: OpticalReferenceMotion.info.id,
            effectID: OpticalGlassEffect.info.id),
    ]

    private static func fixedID(_ string: String) -> UUID {
        guard let id = UUID(uuidString: string) else { preconditionFailure("invalid built-in preset id \(string)") }
        return id
    }
}
