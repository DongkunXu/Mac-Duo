import Foundation

/// What a motion model hands to the effect for one display frame. Angles are hinge angles in
/// degrees (0 = closed): the desktop is pinned to a plane at `referenceAngle`, the physical screen
/// (the glass) is at `lidAngle`.
public struct FoldState: Sendable, Equatable {
    public var lidAngle: Double
    public var referenceAngle: Double
    public var isVisible: Bool

    public init(lidAngle: Double, referenceAngle: Double, isVisible: Bool) {
        self.lidAngle = lidAngle
        self.referenceAngle = referenceAngle
        self.isVisible = isVisible
    }

    /// Signed angle of the glass from the content plane; negative while the lid is more closed.
    public var deviation: Double { lidAngle - referenceAngle }

    public static func hidden(at angle: Double) -> FoldState {
        FoldState(lidAngle: angle, referenceAngle: angle, isVisible: false)
    }
}
