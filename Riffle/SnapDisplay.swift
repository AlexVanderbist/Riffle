import AppKit
import CoreGraphics

/// The Snap Display is the display holding the cursor when a snap fires,
/// else the Resize Display rule applied to the window's start frame.
enum SnapDisplay {
    /// Usable display areas (menu bar and Dock removed) in top-left-origin
    /// screen coordinates, matching AX and CGEvent coordinates.
    @MainActor
    static var visibleFrames: [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return NSScreen.screens.map { screen in
            let v = screen.visibleFrame
            return CGRect(
                x: v.minX,
                y: primaryHeight - v.maxY,
                width: v.width,
                height: v.height
            )
        }
    }

    nonisolated static func visibleFrame(
        for windowFrame: CGRect,
        cursor: CGPoint,
        among frames: [CGRect]
    ) -> CGRect? {
        if let frame = frames.first(where: { $0.insetBy(dx: -0.01, dy: -0.01).contains(cursor) }) {
            return frame
        }
        return ResizeDisplay.bounds(for: windowFrame, cursor: cursor, among: frames)
    }

    /// -1/0/1 per axis when the cursor sits on the outer edge of its display,
    /// i.e. where macOS contains it. A boundary shared with another display
    /// is not an edge: the cursor flows across it.
    nonisolated static func cursorEdge(
        _ cursor: CGPoint,
        among displays: [CGRect],
        tolerance: CGFloat = SnapFeel.cursorEdgeTolerance
    ) -> (x: Int, y: Int) {
        guard let display = displays.first(where: {
            $0.insetBy(dx: -tolerance, dy: -tolerance).contains(cursor)
        }) else { return (0, 0) }

        var edge = (x: 0, y: 0)
        if cursor.x <= display.minX + tolerance { edge.x = -1 }
        if cursor.x >= display.maxX - tolerance { edge.x = 1 }
        if cursor.y <= display.minY + tolerance { edge.y = -1 }
        if cursor.y >= display.maxY - tolerance { edge.y = 1 }

        let others = displays.filter { $0 != display }
        func neighbourContains(_ point: CGPoint) -> Bool {
            others.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        }
        if edge.x != 0, neighbourContains(CGPoint(x: cursor.x + CGFloat(edge.x) * tolerance * 2, y: cursor.y)) {
            edge.x = 0
        }
        if edge.y != 0, neighbourContains(CGPoint(x: cursor.x, y: cursor.y + CGFloat(edge.y) * tolerance * 2)) {
            edge.y = 0
        }
        return edge
    }
}
