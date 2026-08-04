import CoreGraphics
import Foundation

/// Converts a scroll event's raw trackpad deltas into a window translation in
/// top-left-origin screen coordinates. Numbers locked by the gesture-feel
/// prototype (#6) and revised by the screen-edge prototype (#11).
enum MoveFeel {
    static let gain = 1.5
    static let accelerationExponent = 1.2

    /// Axis 1 is vertical, axis 2 horizontal, as reported after macOS applies
    /// the natural-scrolling preference; `isDirectionInvertedFromDevice` undoes
    /// that so the window always follows the fingers.
    static func translation(
        pointDeltaAxis1: Double,
        pointDeltaAxis2: Double,
        isDirectionInvertedFromDevice: Bool
    ) -> CGVector {
        let dx = isDirectionInvertedFromDevice ? pointDeltaAxis2 : -pointDeltaAxis2
        let dy = isDirectionInvertedFromDevice ? pointDeltaAxis1 : -pointDeltaAxis1
        return CGVector(dx: shaped(dx), dy: shaped(dy))
    }

    private static func shaped(_ delta: Double) -> Double {
        let sign: Double = delta < 0 ? -1 : 1
        return sign * pow(abs(delta), accelerationExponent) * gain
    }
}
