import CoreGraphics

/// A layout the Target Window snaps into, expressed inside the Snap Display's
/// visible frame (menu bar and Dock removed).
nonisolated enum SnapLayout: Equatable, CustomStringConvertible {
    case leftHalf
    case rightHalf
    case maximized
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case centered80

    var description: String {
        switch self {
        case .leftHalf: "left half"
        case .rightHalf: "right half"
        case .maximized: "maximized"
        case .topLeftQuarter: "top-left quarter"
        case .topRightQuarter: "top-right quarter"
        case .bottomLeftQuarter: "bottom-left quarter"
        case .bottomRightQuarter: "bottom-right quarter"
        case .centered80: "80% centered"
        }
    }

    /// -1 / 1 for the left / right half, 0 for anything else.
    var halfSide: Int {
        switch self {
        case .leftHalf: -1
        case .rightHalf: 1
        default: 0
        }
    }

    /// Which half a window currently fills, if any.
    static func halfSide(
        of frame: CGRect,
        in visibleFrame: CGRect,
        tolerance: CGFloat = SnapFeel.halfTolerance
    ) -> Int {
        for layout in [SnapLayout.leftHalf, .rightHalf] {
            let candidate = layout.frame(in: visibleFrame)
            if abs(candidate.minX - frame.minX) <= tolerance,
               abs(candidate.minY - frame.minY) <= tolerance,
               abs(candidate.width - frame.width) <= tolerance,
               abs(candidate.height - frame.height) <= tolerance {
                return layout.halfSide
            }
        }
        return 0
    }

    /// `visibleFrame` is in top-left-origin screen coordinates, matching AX
    /// and CGEvent coordinates.
    func frame(in visibleFrame: CGRect) -> CGRect {
        let v = visibleFrame
        let halfWidth = v.width / 2
        let halfHeight = v.height / 2
        switch self {
        case .leftHalf:
            return CGRect(x: v.minX, y: v.minY, width: halfWidth, height: v.height)
        case .rightHalf:
            return CGRect(x: v.midX, y: v.minY, width: halfWidth, height: v.height)
        case .maximized:
            return v
        case .topLeftQuarter:
            return CGRect(x: v.minX, y: v.minY, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: v.midX, y: v.minY, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: v.minX, y: v.midY, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: v.midX, y: v.midY, width: halfWidth, height: halfHeight)
        case .centered80:
            let size = CGSize(width: v.width * 0.8, height: v.height * 0.8)
            return CGRect(
                x: v.midX - size.width / 2,
                y: v.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}
