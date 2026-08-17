import CoreGraphics

nonisolated struct PendingMove {
    struct Target {
        let position: CGPoint
        let targetCursorPosition: CGPoint
        fileprivate let requestedPosition: CGPoint
    }

    private var requestedPosition: CGPoint
    /// Where the cursor grabbed the window, relative to its origin. The
    /// cursor rides along at this offset from wherever the window actually
    /// lands, so an edge or the menu bar stops both together.
    private let grabOffset: CGVector
    private var eventCursorPosition: CGPoint
    private var lastAppliedPosition: CGPoint
    private let windowSize: CGSize
    private let topology: DisplayTopology

    init(frame: CGRect, cursor: CGPoint, topology: DisplayTopology) {
        requestedPosition = frame.origin
        grabOffset = CGVector(dx: cursor.x - frame.origin.x, dy: cursor.y - frame.origin.y)
        eventCursorPosition = cursor
        lastAppliedPosition = frame.origin
        windowSize = frame.size
        self.topology = topology
    }

    var target: Target? {
        guard let position = MoveGeometry.constrain(
            origin: requestedPosition,
            from: lastAppliedPosition,
            windowSize: windowSize,
            cursor: eventCursorPosition,
            topology: topology
        ) else { return nil }

        return Target(
            position: position,
            targetCursorPosition: CGPoint(
                x: position.x + grabOffset.dx,
                y: position.y + grabOffset.dy
            ),
            requestedPosition: requestedPosition
        )
    }

    mutating func apply(_ translation: CGVector, cursor: CGPoint) {
        requestedPosition.x += translation.dx
        requestedPosition.y += translation.dy
        eventCursorPosition = cursor
    }

    mutating func accept(_ target: Target) {
        requestedPosition.x += target.position.x - target.requestedPosition.x
        requestedPosition.y += target.position.y - target.requestedPosition.y
        lastAppliedPosition = target.position
    }
}

nonisolated enum MoveGeometry {
    private static let minimumVisibleLength: CGFloat = 100

    private struct ValidRegion {
        let display: CGRect
        let origins: CGRect
    }

    static func constrain(
        origin: CGPoint,
        from previousOrigin: CGPoint? = nil,
        windowSize: CGSize,
        cursor: CGPoint,
        topology: DisplayTopology
    ) -> CGPoint? {
        let allRegions = zip(topology.displays, topology.menuBarHeights).map { display, menuBarHeight in
            let visibleWidth = min(minimumVisibleLength, windowSize.width, display.width)
            let visibleHeight = min(minimumVisibleLength, windowSize.height, display.height)
            let minimumX = display.minX - windowSize.width + visibleWidth
            let maximumX = display.maxX - visibleWidth
            let maximumY = display.maxY - visibleHeight
            // macOS pins a window's top edge below the menu bar; requesting
            // anything higher is silently clamped, so clamp here instead and
            // keep the requested position, cursor and window in step.
            let overhangMinimumY = display.minY - windowSize.height + visibleHeight
            let minimumY = menuBarHeight > 0
                ? min(max(overhangMinimumY, display.minY + menuBarHeight), maximumY)
                : overhangMinimumY

            return ValidRegion(
                display: display,
                origins: CGRect(
                    x: minimumX,
                    y: minimumY,
                    width: maximumX - minimumX,
                    height: maximumY - minimumY
                )
            )
        }
        let selectedRegions = previousOrigin.map { origin in
            reachableRegions(containing: origin, among: allRegions)
        } ?? allRegions

        return selectedRegions.map { region in
            let constrained = CGPoint(
                x: min(
                    max(origin.x, region.origins.minX),
                    region.origins.maxX
                ),
                y: min(
                    max(origin.y, region.origins.minY),
                    region.origins.maxY
                )
            )
            let dx = origin.x - constrained.x
            let dy = origin.y - constrained.y

            return (
                origin: constrained,
                squaredDistance: dx * dx + dy * dy,
                containsPointer: region.display.contains(cursor),
                isMain: region.display == topology.mainDisplay
            )
        }.min { lhs, rhs in
            if lhs.squaredDistance != rhs.squaredDistance {
                return lhs.squaredDistance < rhs.squaredDistance
            }
            if lhs.containsPointer != rhs.containsPointer {
                return lhs.containsPointer
            }
            if lhs.isMain != rhs.isMain {
                return lhs.isMain
            }

            return false
        }?.origin
    }

    private static func reachableRegions(
        containing origin: CGPoint,
        among regions: [ValidRegion]
    ) -> [ValidRegion] {
        let containingRegions = regions.filter { contains(origin, in: $0.origins) }

        return containingRegions.isEmpty ? regions : containingRegions
    }

    private static func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        point.x >= bounds.minX && point.x <= bounds.maxX
            && point.y >= bounds.minY && point.y <= bounds.maxY
    }
}
