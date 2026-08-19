import CoreGraphics

/// One trackpad contact from a gesture event, in normalized trackpad
/// coordinates (0...1 on each axis, y up).
nonisolated struct TrackpadTouch: Equatable {
    let id: Int
    let isTouching: Bool
    let normalizedPosition: CGPoint
}
