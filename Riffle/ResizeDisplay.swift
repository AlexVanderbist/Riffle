import AppKit
import CoreGraphics

enum ResizeDisplay {
    static func bounds(for windowFrame: CGRect, cursor: CGPoint, among displays: [CGRect]) -> CGRect? {
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

        if let display = displays.first(where: { contains(windowCenter, in: $0) }) {
            return display
        }
        if let display = displays.first(where: { contains(cursor, in: $0) }) {
            return display
        }

        return displays.min { lhs, rhs in
            squaredDistance(from: windowCenter, to: lhs) < squaredDistance(from: windowCenter, to: rhs)
        }
    }

    static var activeBounds: [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            return CGDisplayBounds(CGDirectDisplayID(displayNumber.uint32Value))
        }
    }

    private static func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        bounds.insetBy(dx: -0.01, dy: -0.01).contains(point)
    }

    private static func squaredDistance(from point: CGPoint, to bounds: CGRect) -> CGFloat {
        let nearest = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        let dx = point.x - nearest.x
        let dy = point.y - nearest.y

        return dx * dx + dy * dy
    }
}
