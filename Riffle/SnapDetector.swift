import CoreGraphics
import Foundation

/// Decides, per applied translation, whether the window is pinned on an axis.
nonisolated enum SnapPinning {
    /// An axis moved when the constrained position changed on it, unless the
    /// cursor is contained at the display edge in the push direction — then
    /// the window may still slide off-screen but the user is pressing.
    /// A zero translation on an axis is not a press, so it counts as moved.
    static func pinned(
        translation: CGVector,
        before: CGPoint,
        after: CGPoint,
        cursorEdge: (x: Int, y: Int)
    ) -> (movedX: Bool, movedY: Bool) {
        let pushX = translation.dx < 0 ? -1 : (translation.dx > 0 ? 1 : 0)
        let pushY = translation.dy < 0 ? -1 : (translation.dy > 0 ? 1 : 0)
        return (
            movedX: translation.dx == 0 || (abs(after.x - before.x) > 0.01 && cursorEdge.x != pushX),
            movedY: translation.dy == 0 || (abs(after.y - before.y) > 0.01 && cursorEdge.y != pushY)
        )
    }
}

/// Pure state machine over the Move Gesture's applied translations that
/// decides when a Snap Gesture fires: Flick on lift, Edge Press and Corner
/// Press while pinned, Wiggle while moving.
nonisolated struct SnapDetector {
    private struct Sample {
        let time: TimeInterval
        let translation: CGVector
    }

    let enabledGestures: Set<SnapGesture>
    /// -1 when the window currently fills the left half, 1 for the right
    /// half, 0 otherwise. Up/down then means the quarter on that side.
    private(set) var currentHalf: Int

    private var recent: [Sample] = []
    private var pressure = CGVector.zero
    private var pinnedDirection = (x: 0, y: 0)
    private var sideForX: CGFloat = 0
    private var sideForY: CGFloat = 0
    private var wiggleRunDirection = 0
    private var wiggleRunLength: CGFloat = 0
    private var wiggleRunCounted = false
    private var wiggleRunTimes: [TimeInterval] = []

    init(enabledGestures: Set<SnapGesture>, currentHalf: Int = 0) {
        self.enabledGestures = enabledGestures
        self.currentHalf = currentHalf
    }

    /// Feed one applied translation. `movedX`/`movedY` say whether the window
    /// moved on that axis for this translation (see `SnapPinning`).
    mutating func observe(
        translation: CGVector,
        movedX: Bool,
        movedY: Bool,
        now: TimeInterval
    ) -> SnapLayout? {
        recent.append(Sample(time: now, translation: translation))
        recent.removeAll { now - $0.time > SnapFeel.flickWindow }

        if let layout = observeWiggle(dx: translation.dx, now: now) {
            return enabledGestures.contains(.wiggle) ? layout : nil
        }
        guard let layout = observePress(translation: translation, movedX: movedX, movedY: movedY) else {
            return nil
        }
        let isCorner = layout.halfSide == 0 && layout != .maximized && currentHalf == 0
        return enabledGestures.contains(isCorner ? .cornerPress : .edgePress) ? layout : nil
    }

    /// Call on finger lift; a Flick snaps.
    func flickLayout(now: TimeInterval) -> SnapLayout? {
        guard enabledGestures.contains(.flick) else { return nil }
        let sum = recent
            .filter { now - $0.time <= SnapFeel.flickWindow }
            .reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.translation.dx, dy: $0.dy + $1.translation.dy) }
        let magnitude = hypot(sum.dx, sum.dy)
        guard magnitude >= SnapFeel.flickDistance else { return nil }

        if abs(sum.dx) >= magnitude * SnapFeel.flickDominance {
            return sum.dx < 0 ? .leftHalf : .rightHalf
        }
        if abs(sum.dy) >= magnitude * SnapFeel.flickDominance {
            return Self.layout(horizontal: currentHalf, vertical: sum.dy < 0 ? -1 : 1)
        }
        return nil
    }

    /// Forget the gesture so far, keeping which half the window now fills.
    mutating func reset(currentHalf: Int) {
        self = SnapDetector(enabledGestures: enabledGestures, currentHalf: currentHalf)
    }

    /// While an axis is pinned, the push into it accumulates as pressure and
    /// the sideways component accumulates as `side`. On firing, a clear
    /// sideways component (or the other axis being pinned) picks a corner.
    private mutating func observePress(translation: CGVector, movedX: Bool, movedY: Bool) -> SnapLayout? {
        func direction(_ value: CGFloat) -> Int { value < 0 ? -1 : (value > 0 ? 1 : 0) }

        if translation.dx != 0 {
            let dir = direction(translation.dx)
            if movedX {
                pinnedDirection.x = 0
                pressure.dx = 0
                sideForX = 0
            } else {
                if dir != pinnedDirection.x {
                    pressure.dx = 0
                    sideForX = 0
                }
                pinnedDirection.x = dir
                pressure.dx += translation.dx
            }
        }
        if translation.dy != 0 {
            let dir = direction(translation.dy)
            if movedY {
                pinnedDirection.y = 0
                pressure.dy = 0
                sideForY = 0
            } else {
                if dir != pinnedDirection.y {
                    pressure.dy = 0
                    sideForY = 0
                }
                pinnedDirection.y = dir
                pressure.dy += translation.dy
            }
        }
        if pinnedDirection.x != 0 { sideForX += translation.dy }
        if pinnedDirection.y != 0 { sideForY += translation.dx }

        let px = pinnedDirection.x
        let py = pinnedDirection.y
        let threshold = (px != 0 && py != 0) ? SnapFeel.cornerPressDistance : SnapFeel.pressDistance

        if py != 0, abs(pressure.dy) >= threshold {
            var sideways = abs(sideForY) >= abs(pressure.dy) * SnapFeel.cornerSideShare ? direction(sideForY) : px
            if sideways == 0 { sideways = currentHalf }
            clearPress()
            return Self.layout(horizontal: sideways, vertical: py)
        }
        if px != 0, abs(pressure.dx) >= threshold {
            let sideways = abs(sideForX) >= abs(pressure.dx) * SnapFeel.cornerSideShare ? direction(sideForX) : py
            clearPress()
            return Self.layout(horizontal: px, vertical: sideways)
        }
        return nil
    }

    private mutating func clearPress() {
        pressure = .zero
        sideForX = 0
        sideForY = 0
    }

    private static func layout(horizontal: Int, vertical: Int) -> SnapLayout? {
        switch (horizontal, vertical) {
        case (-1, -1): return .topLeftQuarter
        case (1, -1): return .topRightQuarter
        case (-1, 1): return .bottomLeftQuarter
        case (1, 1): return .bottomRightQuarter
        case (-1, 0): return .leftHalf
        case (1, 0): return .rightHalf
        case (0, -1): return .maximized
        default: return nil
        }
    }

    private mutating func observeWiggle(dx: CGFloat, now: TimeInterval) -> SnapLayout? {
        guard dx != 0 else { return nil }
        let dir = dx < 0 ? -1 : 1
        if dir == wiggleRunDirection {
            wiggleRunLength += abs(dx)
        } else {
            wiggleRunDirection = dir
            wiggleRunLength = abs(dx)
            wiggleRunCounted = false
        }
        // A run only counts once it is long enough, so jitter never counts.
        if !wiggleRunCounted, wiggleRunLength >= SnapFeel.wiggleRunLength {
            wiggleRunCounted = true
            wiggleRunTimes.append(now)
        }
        wiggleRunTimes.removeAll { now - $0 > SnapFeel.wiggleWindow }
        // N reversals = N + 1 alternating runs.
        guard wiggleRunTimes.count >= SnapFeel.wiggleReversals + 1 else { return nil }
        wiggleRunTimes.removeAll()
        return .centered80
    }
}
