import Foundation

public enum FoldLimits {
    /// Hard ceiling: nothing is ever drawn at or above this lid angle, whatever a motion model is
    /// tuned to. Models usually release lower (`MotionModel.releaseAngleParameter`). The render host
    /// leaves violations visible, and `FoldLimitsInvariantTests` checks every model.
    public static let releaseAngle: Double = 120
}
