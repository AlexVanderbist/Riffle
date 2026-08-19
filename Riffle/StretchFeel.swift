import CoreGraphics

/// Converts a Directional Pinch's finger-separation change into a size change.
/// Numbers live in code, not Preferences (ADR-0002).
enum StretchFeel {
    /// How much of the Resize Display one full trackpad of separation change
    /// covers: 2.0 means spreading two fingers from touching to the trackpad's
    /// full width adds twice the display width. Finger separation can only
    /// change by a fraction of the trackpad, so this runs hotter than 1:1.
    static let displayFractionPerTrackpad = 2.0

    /// Shortest edge a Directional Pinch will shrink a window to, unless it
    /// already started smaller.
    static let minimumEdge: CGFloat = 200

    /// The size change for a separation change given in normalized trackpad
    /// units (0...1 across each trackpad axis). Spreading horizontally widens,
    /// spreading vertically heightens.
    static func translation(
        normalizedDelta: CGVector,
        displayBounds: CGRect
    ) -> CGVector {
        CGVector(
            dx: normalizedDelta.dx * displayBounds.width * displayFractionPerTrackpad,
            dy: normalizedDelta.dy * displayBounds.height * displayFractionPerTrackpad
        )
    }
}
