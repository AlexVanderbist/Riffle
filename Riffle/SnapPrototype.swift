import AppKit
import CoreGraphics
import Foundation
import os

// PROTOTYPE — throwaway. Snap-to-layout gestures layered on the Move Gesture:
//
//   • flick left / right / up on finger lift → left half / right half / maximize
//   • press the pinned window into a side      → left half / right half / maximize
//   • press the pinned window into a corner    → quarter in that corner
//   • wiggle horizontally while moving         → 80% centered
//
// All numbers below are feel knobs. Nothing here is production code.

nonisolated enum SnapLayout: CustomStringConvertible {
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

    /// Which half a window currently fills, if any (tolerance in points).
    nonisolated static func halfSide(of frame: CGRect, in visibleFrame: CGRect, tolerance: CGFloat = 6) -> Int {
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

    /// `visibleFrame` is the display's usable area (menu bar and Dock removed)
    /// in top-left-origin screen coordinates.
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

/// PROTOTYPE: each snap trigger can be switched off from the status menu.
nonisolated enum SnapGesture: String, CaseIterable {
    case flick
    case edgePress
    case cornerPress
    case wiggle

    var menuTitle: String {
        switch self {
        case .flick: "Flick to Half / Maximize"
        case .edgePress: "Press Into Edge"
        case .cornerPress: "Press Into Corner"
        case .wiggle: "Wiggle to Center"
        }
    }

    private var key: String { "snapPrototype.\(rawValue)" }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

/// Watches the stream of applied translations and decides when a snap fires.
nonisolated struct SnapDetector {
    // MARK: Feel knobs

    /// A finger lift counts as a flick when the shaped translation over the
    /// last `flickWindow` seconds exceeds this many points.
    static let flickDistance: CGFloat = 220
    static let flickWindow: TimeInterval = 0.09
    /// The dominant axis must carry at least this share of the flick.
    static let flickDominance: CGFloat = 0.8

    /// Shaped points pushed into a pinned edge before it snaps; less once the
    /// window is pinned in a corner, so corners win over the edges leading to them.
    static let pressDistance: CGFloat = 260
    static let cornerPressDistance: CGFloat = 140
    /// Sideways travel during a press, as a share of the press, that turns an
    /// edge press into a corner press.
    static let cornerSideShare: CGFloat = 0.35

    /// Horizontal direction reversals within `wiggleWindow` seconds; each run
    /// between reversals must cover at least `wiggleRunLength` points.
    static let wiggleReversals = 5
    static let wiggleWindow: TimeInterval = 0.7
    static let wiggleRunLength: CGFloat = 30

    // MARK: State

    private struct Sample {
        let time: TimeInterval
        let translation: CGVector
    }

    private var recent: [Sample] = []
    private var pressure = CGVector.zero
    /// -1 when the window currently fills the left half, 1 for the right
    /// half, 0 otherwise. Up/down then means the quarter on that side.
    var currentHalf = 0
    private var pinnedDirection = (x: 0, y: 0)
    private var sideForX: CGFloat = 0
    private var sideForY: CGFloat = 0
    private var wiggleRunDirection = 0
    private var wiggleRunLength: CGFloat = 0
    private var wiggleRunCounted = false
    private var wiggleRunTimes: [TimeInterval] = []

    /// Feed one applied translation. `movedX`/`movedY` say whether the window
    /// actually moved on that axis for this translation, i.e. whether it is
    /// pinned against an edge.
    mutating func observe(
        translation: CGVector,
        movedX: Bool,
        movedY: Bool,
        now: TimeInterval
    ) -> SnapLayout? {
        recent.append(Sample(time: now, translation: translation))
        recent.removeAll { now - $0.time > Self.flickWindow }

        if let layout = observeWiggle(dx: translation.dx, now: now) {
            return SnapGesture.wiggle.isEnabled ? layout : nil
        }
        guard let layout = observePress(translation: translation, movedX: movedX, movedY: movedY) else { return nil }
        let isCorner = layout.halfSide == 0 && layout != .maximized && currentHalf == 0
        return (isCorner ? SnapGesture.cornerPress : SnapGesture.edgePress).isEnabled ? layout : nil
    }

    /// Call on finger lift; a flick snaps.
    func flickLayout(now: TimeInterval) -> SnapLayout? {
        guard SnapGesture.flick.isEnabled else { return nil }
        let sum = recent
            .filter { now - $0.time <= Self.flickWindow }
            .reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.translation.dx, dy: $0.dy + $1.translation.dy) }
        let magnitude = hypot(sum.dx, sum.dy)
        guard magnitude >= Self.flickDistance else { return nil }

        if abs(sum.dx) >= magnitude * Self.flickDominance {
            return sum.dx < 0 ? .leftHalf : .rightHalf
        }
        if abs(sum.dy) >= magnitude * Self.flickDominance {
            return Self.layout(horizontal: currentHalf, vertical: sum.dy < 0 ? -1 : 1)
        }
        return nil
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
        let threshold = (px != 0 && py != 0) ? Self.cornerPressDistance : Self.pressDistance

        if py != 0, abs(pressure.dy) >= threshold {
            var sideways = abs(sideForY) >= abs(pressure.dy) * Self.cornerSideShare ? direction(sideForY) : px
            if sideways == 0 { sideways = currentHalf }
            pressure = .zero
            sideForX = 0
            sideForY = 0
            return Self.layout(horizontal: sideways, vertical: py)
        }
        if px != 0, abs(pressure.dx) >= threshold {
            let sideways = abs(sideForX) >= abs(pressure.dx) * Self.cornerSideShare ? direction(sideForX) : py
            pressure = .zero
            sideForX = 0
            sideForY = 0
            return Self.layout(horizontal: px, vertical: sideways)
        }
        return nil
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

    /// Forget everything except which half the window now fills; used after
    /// a snap that keeps the gesture alive.
    mutating func reset(currentHalf: Int) {
        self = SnapDetector()
        self.currentHalf = currentHalf
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
        if !wiggleRunCounted, wiggleRunLength >= Self.wiggleRunLength {
            wiggleRunCounted = true
            wiggleRunTimes.append(now)
        }
        wiggleRunTimes.removeAll { now - $0 > Self.wiggleWindow }
        // N reversals = N + 1 alternating runs.
        guard wiggleRunTimes.count >= Self.wiggleReversals + 1 else { return nil }
        wiggleRunTimes.removeAll()
        return .centered80
    }
}

enum SnapDisplays {
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

    /// The display holding the cursor, else the one holding the window
    /// center, else the nearest to the window center.
    nonisolated static func visibleFrame(for windowFrame: CGRect, cursor: CGPoint, among frames: [CGRect]) -> CGRect? {
        if let frame = frames.first(where: { $0.insetBy(dx: -0.01, dy: -0.01).contains(cursor) }) {
            return frame
        }
        return ResizeDisplay.bounds(for: windowFrame, cursor: cursor, among: frames)
    }
}
