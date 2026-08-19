import CoreGraphics

/// Pure tracker for a directional pinch: reports how much the horizontal and
/// vertical separation between two fingers changed since the last snapshot.
/// Spreading fingers apart horizontally gives +dx, vertically +dy.
nonisolated struct TwoFingerSpread {
    static let fingerCount = 2

    private var lastSpread: CGVector?

    mutating func handle(touches: [TrackpadTouch]) -> CGVector? {
        // Magnify frames carry no touch data; only the raw gesture frames
        // between them do. A frame without touches says nothing about the
        // fingers, so it must not reset the tracker.
        guard !touches.isEmpty else { return nil }

        let touching = touches.filter(\.isTouching)
        guard touching.count == Self.fingerCount else {
            lastSpread = nil
            return nil
        }

        let first = touching[0].normalizedPosition
        let second = touching[1].normalizedPosition
        let spread = CGVector(dx: abs(first.x - second.x), dy: abs(first.y - second.y))
        defer { lastSpread = spread }
        guard let lastSpread else { return nil }

        return CGVector(dx: spread.dx - lastSpread.dx, dy: spread.dy - lastSpread.dy)
    }
}
