import CoreGraphics
import Foundation

/// Thresholds for the Snap Gestures. Numbers locked by the snapping
/// prototype; every one of them is in shaped translation points (see
/// `MoveFeel`) unless noted.
enum SnapFeel {
    /// A finger lift is a Flick when the translation over the last
    /// `flickWindow` seconds covers at least `flickDistance` and the dominant
    /// axis carries at least `flickDominance` of it.
    static let flickDistance: CGFloat = 220
    static let flickWindow: TimeInterval = 0.09
    static let flickDominance: CGFloat = 0.8

    /// Push into a Pinned Axis before an Edge Press fires; less once both
    /// axes are pinned, so corners win over the edges leading to them.
    static let pressDistance: CGFloat = 260
    static let cornerPressDistance: CGFloat = 140
    /// Sideways travel during a press, as a share of the press, that turns an
    /// Edge Press into a Corner Press.
    static let cornerSideShare: CGFloat = 0.35

    /// A Wiggle is `wiggleReversals` horizontal reversals within
    /// `wiggleWindow` seconds; each run between reversals must cover at least
    /// `wiggleRunLength`.
    static let wiggleReversals = 5
    static let wiggleWindow: TimeInterval = 0.7
    static let wiggleRunLength: CGFloat = 30

    /// Translations are ignored this long after a snap so the tail of the
    /// push does not drag the freshly snapped window away.
    static let settleTime: TimeInterval = 0.25

    /// Screen points a window may differ from a half layout and still count
    /// as filling that half.
    static let halfTolerance: CGFloat = 6
    /// Screen points from a display's outer edge within which the cursor
    /// counts as contained there.
    static let cursorEdgeTolerance: CGFloat = 2
    /// Screen points the cursor is kept inside a snapped frame.
    static let cursorPullInset: CGFloat = 20
}
