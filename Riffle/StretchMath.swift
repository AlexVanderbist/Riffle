import CoreGraphics

/// Pending frame state of one Directional Pinch: horizontal finger-separation
/// change becomes width, vertical becomes height.
///
/// Each axis is anchored to the Resize Display proportionally: the gap between
/// the window and each display edge keeps its share of the total free space on
/// that axis. A centered window grows evenly, a window touching the left edge
/// keeps touching it, a window one third of the way across stays one third of
/// the way across.
nonisolated struct PendingStretch: PendingFrameAdjustment {
    struct Target: PendingFrameTarget {
        let frame: CGRect
        fileprivate let swipe: CGVector
    }

    private var baseFrame: CGRect
    private let displayBounds: CGRect
    private let minimumWidth: CGFloat
    private let minimumHeight: CGFloat
    /// Accumulated finger-separation change in normalized trackpad units
    /// (0...1 across each axis): +dx widens, +dy heightens.
    private var pendingSwipe = CGVector.zero

    init(frame: CGRect, displayBounds: CGRect) {
        baseFrame = frame
        self.displayBounds = displayBounds
        minimumWidth = min(StretchFeel.minimumEdge, frame.width)
        minimumHeight = min(StretchFeel.minimumEdge, frame.height)
    }

    var target: Target {
        let translation = StretchFeel.translation(normalizedDelta: pendingSwipe, displayBounds: displayBounds)
        // A window already larger than the display may shrink but not grow.
        let width = clamped(
            baseFrame.width + translation.dx,
            minimum: minimumWidth,
            maximum: max(displayBounds.width, baseFrame.width)
        )
        let height = clamped(
            baseFrame.height + translation.dy,
            minimum: minimumHeight,
            maximum: max(displayBounds.height, baseFrame.height)
        )

        let frame = CGRect(
            x: Self.anchoredOrigin(
                from: baseFrame.minX,
                length: baseFrame.width,
                to: width,
                displayMin: displayBounds.minX,
                displayMax: displayBounds.maxX
            ),
            y: Self.anchoredOrigin(
                from: baseFrame.minY,
                length: baseFrame.height,
                to: height,
                displayMin: displayBounds.minY,
                displayMax: displayBounds.maxY
            ),
            width: width,
            height: height
        )

        return Target(frame: frame, swipe: pendingSwipe)
    }

    var targetFrame: CGRect { target.frame }

    /// Adds separation change in normalized trackpad units: +dx widens, +dy
    /// heightens.
    mutating func apply(_ normalizedDelta: CGVector) {
        pendingSwipe.dx += normalizedDelta.dx
        pendingSwipe.dy += normalizedDelta.dy
    }

    mutating func accept(to acceptedFrame: CGRect, consuming target: Target) {
        guard acceptedFrame != target.frame else { return }

        baseFrame = acceptedFrame
        pendingSwipe.dx -= target.swipe.dx
        pendingSwipe.dy -= target.swipe.dy
    }

    /// The origin on one axis after the length changes, keeping the leading
    /// gap's share of the free space on the display.
    static func anchoredOrigin(
        from origin: CGFloat,
        length: CGFloat,
        to newLength: CGFloat,
        displayMin: CGFloat,
        displayMax: CGFloat
    ) -> CGFloat {
        let leadingGap = origin - displayMin
        let trailingGap = displayMax - (origin + length)
        let freeSpace = leadingGap + trailingGap
        // No free space to share: the window fills or overflows the display,
        // so resize around its own center instead.
        guard freeSpace > 0 else { return origin - (newLength - length) / 2 }

        let leadingShare = min(max(leadingGap / freeSpace, 0), 1)
        let newFreeSpace = (displayMax - displayMin) - newLength

        return displayMin + newFreeSpace * leadingShare
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}
