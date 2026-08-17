import AppKit
import ApplicationServices
import os

/// One Move Gesture against one Target Window.
///
/// The window under the cursor is hit-tested once, when the gesture begins,
/// and stays the target until the gesture ends. The tap callback only
/// accumulates deltas into a target position; a dedicated serial worker writes
/// the newest target via AX, throttled to `writeInterval`, so a slow app lags
/// at most one write instead of replaying a queued backlog. On finger lift the
/// window freezes at the last successfully applied frame — pending targets are
/// dropped.
// @unchecked Sendable: mutable state is confined to `shared`'s lock; the AX
// element refs are immutable and AX calls on them are thread-safe IPC.
nonisolated final class MoveWindowSession: @unchecked Sendable {
    /// Called on the main thread when a mid-gesture AX write fails hard and
    /// the session has shut itself down.
    var onInvalidated: (@MainActor (AXError) -> Void)?

    private let targetWindow: TargetWindow
    private let displayTopology: DisplayTopology
    private let writeInterval: TimeInterval

    private struct GestureState {
        var move: PendingMove
        var isDirty = false
        var isDraining = false
        var isEnded = false
        // PROTOTYPE
        var snapDetector = SnapDetector()
        var lastCursor: CGPoint
        var settleUntil: TimeInterval = 0
    }

    /// PROTOTYPE: deltas are ignored this long after a snap so the tail of
    /// the push does not drag the freshly snapped window away.
    private static let snapSettleTime: TimeInterval = 0.25

    /// PROTOTYPE: what the caller should do with the session after `apply`.
    enum ApplyOutcome {
        case moving
        case ended
    }

    // PROTOTYPE
    private let snapVisibleFrames: [CGRect]
    private let startFrame: CGRect

    private let state: OSAllocatedUnfairLock<GestureState>
    private let writeGate = OSAllocatedUnfairLock(initialState: ())
    private let axQueue = DispatchQueue(label: "com.alexvanderbist.Riffle.ax-writes", qos: .userInteractive)
    private static let logger = Logger(subsystem: "com.alexvanderbist.Riffle", category: "move-session")

    // AX calls into a hung app block until this timeout instead of wedging
    // the caller for the default several seconds.
    /// Prepares the hit-tested window under `cursor` for a Move Gesture.
    /// Returns nil when there is no window or it refuses to report its frame;
    /// the gesture is still consumed by the caller, it just moves nothing.
    @MainActor
    static func begin(
        targeting element: AXUIElement?,
        at cursor: CGPoint,
        writeInterval: TimeInterval
    ) -> MoveWindowSession? {
        guard let element else {
            logger.info("No window under the cursor — move gesture targets nothing")
            return nil
        }
        guard let position = TargetWindow.position(of: element),
              let size = TargetWindow.size(of: element) else {
            logger.warning("Target window refuses to report its frame — move gesture targets nothing")
            return nil
        }

        return MoveWindowSession(
            targetWindow: TargetWindow(element: element),
            startPosition: position,
            startCursor: cursor,
            windowSize: size,
            displayTopology: DisplayTopology.current,
            snapVisibleFrames: SnapDisplays.visibleFrames,
            writeInterval: writeInterval
        )
    }

    private init(
        targetWindow: TargetWindow,
        startPosition: CGPoint,
        startCursor: CGPoint,
        windowSize: CGSize,
        displayTopology: DisplayTopology,
        snapVisibleFrames: [CGRect],
        writeInterval: TimeInterval
    ) {
        self.targetWindow = targetWindow
        self.displayTopology = displayTopology
        self.snapVisibleFrames = snapVisibleFrames
        self.startFrame = CGRect(origin: startPosition, size: windowSize)
        self.writeInterval = writeInterval
        var detector = SnapDetector()
        if let visible = SnapDisplays.visibleFrame(for: startFrame, cursor: startCursor, among: snapVisibleFrames) {
            detector.currentHalf = SnapLayout.halfSide(of: startFrame, in: visible)
        }
        self.state = OSAllocatedUnfairLock(initialState: GestureState(
            move: PendingMove(
                frame: CGRect(origin: startPosition, size: windowSize),
                cursor: startCursor,
                topology: displayTopology
            ),
            snapDetector: detector,
            lastCursor: startCursor
        ))
    }

    /// PROTOTYPE: -1/0/1 per axis when the cursor sits on the outer edge of
    /// its display, i.e. macOS is containing it there.
    private func cursorEdge(_ cursor: CGPoint) -> (x: Int, y: Int) {
        let tolerance: CGFloat = 2
        guard let display = displayTopology.displays.first(where: {
            $0.insetBy(dx: -tolerance, dy: -tolerance).contains(cursor)
        }) else { return (0, 0) }
        var edge = (x: 0, y: 0)
        if cursor.x <= display.minX + tolerance { edge.x = -1 }
        if cursor.x >= display.maxX - tolerance { edge.x = 1 }
        if cursor.y <= display.minY + tolerance { edge.y = -1 }
        if cursor.y >= display.maxY - tolerance { edge.y = 1 }
        return edge
    }

    /// Accumulates a translation into the target position and kicks the worker
    /// if it is idle. Fast enough for the tap callback: no AX work happens here.
    @MainActor
    func apply(_ translation: CGVector, cursor: CGPoint) -> ApplyOutcome {
        guard displayTopology == DisplayTopology.current else {
            endForTopologyChange()
            return .ended
        }
        guard !displayTopology.displays.isEmpty else { return .moving }

        let now = CFAbsoluteTimeGetCurrent()
        let edge = cursorEdge(cursor)
        var rebase: (frame: CGRect, cursor: CGPoint, layout: SnapLayout)?
        let shouldDrain = state.withLock { state -> Bool in
            guard !state.isEnded else { return false }
            guard now >= state.settleUntil else { return false }
            // PROTOTYPE: compare the constrained position before and after to
            // learn whether the window is pinned against an edge. The cursor
            // being contained at a display edge counts as pinned as well.
            let before = state.move.target?.position
            state.move.apply(translation, cursor: cursor)
            state.lastCursor = cursor
            let after = state.move.target?.position
            var snap: SnapLayout?
            if let before, let after {
                let pushX = translation.dx < 0 ? -1 : (translation.dx > 0 ? 1 : 0)
                let pushY = translation.dy < 0 ? -1 : (translation.dy > 0 ? 1 : 0)
                snap = state.snapDetector.observe(
                    translation: translation,
                    movedX: translation.dx == 0 || (abs(after.x - before.x) > 0.01 && edge.x != pushX),
                    movedY: translation.dy == 0 || (abs(after.y - before.y) > 0.01 && edge.y != pushY),
                    now: now
                )
            }
            if let snap, let frame = snapFrame(for: snap, cursor: cursor) {
                // Keep the gesture alive on the new frame. The cursor stays
                // put when it is inside the frame, else it is pulled inside.
                let inset = frame.insetBy(dx: min(20, frame.width / 4), dy: min(20, frame.height / 4))
                let newCursor = CGPoint(
                    x: min(max(cursor.x, inset.minX), inset.maxX),
                    y: min(max(cursor.y, inset.minY), inset.maxY)
                )
                state.move = PendingMove(frame: frame, cursor: newCursor, topology: displayTopology)
                state.snapDetector.reset(currentHalf: snap.halfSide)
                state.isDirty = false
                state.settleUntil = now + Self.snapSettleTime
                rebase = (frame, newCursor, snap)
                return false
            }
            state.isDirty = true
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        if let rebase {
            Self.logger.info("SNAP \(rebase.layout.description) -> \(rebase.frame.origin.x),\(rebase.frame.origin.y) \(rebase.frame.width)x\(rebase.frame.height)")
            axQueue.async { [self] in
                writeGate.withLock { _ in
                    write(frame: rebase.frame)
                    if rebase.cursor != cursor { warpCursor(to: rebase.cursor) }
                }
            }
            return .moving
        }
        guard shouldDrain else { return .moving }
        axQueue.async { [self] in drain() }

        return .moving
    }

    /// PROTOTYPE: finger lift; a flick snaps, anything else just ends.
    func liftFingers() {
        let now = CFAbsoluteTimeGetCurrent()
        let flick = state.withLock { state -> (SnapLayout, CGPoint)? in
            guard !state.isEnded, let layout = state.snapDetector.flickLayout(now: now) else { return nil }
            state.isEnded = true
            state.isDirty = false
            return (layout, state.lastCursor)
        }
        guard let flick else {
            end()
            return
        }
        performSnap(flick.0, cursor: flick.1)
    }

    private func snapFrame(for layout: SnapLayout, cursor: CGPoint) -> CGRect? {
        SnapDisplays.visibleFrame(for: startFrame, cursor: cursor, among: snapVisibleFrames)
            .map { layout.frame(in: $0) }
    }

    /// PROTOTYPE: writes the layout frame and finishes the session.
    private func performSnap(_ layout: SnapLayout, cursor: CGPoint) {
        guard let frame = snapFrame(for: layout, cursor: cursor) else {
            Self.logger.warning("SNAP \(layout.description): no display")
            finishEnding(wasAlreadyEnded: false)
            return
        }
        Self.logger.info("SNAP \(layout.description) -> \(frame.origin.x),\(frame.origin.y) \(frame.width)x\(frame.height)")
        axQueue.async { [self] in
            writeGate.withLock { _ in write(frame: frame) }
            restoreEnhancedUIIfNeeded()
        }
    }

    private func write(frame: CGRect) {
        _ = targetWindow.set(position: frame.origin)
        _ = targetWindow.set(size: frame.size)
        _ = targetWindow.set(position: frame.origin)
    }

    /// Ends the gesture: pending un-applied targets are dropped, never snapped
    /// to, and the target app's Enhanced UI setting is restored.
    func end() {
        finishEnding(wasAlreadyEnded: markEnded())
    }

    /// Waits for an in-flight write before ending so a frame from the old
    /// display topology cannot land after cancellation completes.
    func endForTopologyChange() {
        let wasAlreadyEnded = writeGate.withLock { _ in
            markEnded()
        }

        finishEnding(wasAlreadyEnded: wasAlreadyEnded)
    }

    private func markEnded() -> Bool {
        let wasEnded = state.withLock { state in
            let wasEnded = state.isEnded
            state.isEnded = true
            state.isDirty = false
            return wasEnded
        }

        return wasEnded
    }

    private func finishEnding(wasAlreadyEnded: Bool) {
        guard !wasAlreadyEnded else { return }

        axQueue.async { [self] in restoreEnhancedUIIfNeeded() }
    }

    // MARK: - Serial write worker

    private func drain() {
        while true {
            let target = state.withLock { state -> PendingMove.Target? in
                guard state.isDirty, !state.isEnded else {
                    state.isDraining = false
                    return nil
                }
                state.isDirty = false
                return state.move.target
            }
            guard let target else { return }

            let writeStarted = CFAbsoluteTimeGetCurrent()
            let error = writeGate.withLock { _ -> AXError? in
                guard state.withLock({ !$0.isEnded }) else { return nil }

                return write(position: target.position)
            }
            guard let error else { return }

            switch error {
            case .success:
                let shouldWarpCursor = state.withLock { state -> Bool in
                    guard !state.isEnded else { return false }
                    state.move.accept(target)
                    return true
                }
                if shouldWarpCursor {
                    warpCursor(to: target.targetCursorPosition)
                }
            case .invalidUIElement, .apiDisabled:
                // The window is gone or Accessibility was revoked — the
                // gesture ends here; the stream stays consumed upstream.
                invalidate(with: error)
                return
            default:
                // Transient failure (busy or hung app): keep trying, the
                // messaging timeout bounds each attempt.
                break
            }

            // Writing faster than the display refreshes is wasted IPC.
            let elapsed = CFAbsoluteTimeGetCurrent() - writeStarted
            if elapsed < writeInterval {
                Thread.sleep(forTimeInterval: writeInterval - elapsed)
            }
        }
    }

    private func write(position: CGPoint) -> AXError {
        targetWindow.set(position: position)
    }

    /// The cursor keeps its grab offset from the window, so it stops where
    /// the window stops and comes back the moment the window does.
    private func warpCursor(to position: CGPoint) {
        CGWarpMouseCursorPosition(position)
        // Reset the post-warp suppression interval so the gesture stream keeps
        // flowing uninterrupted.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func invalidate(with error: AXError) {
        Self.logger.warning("Mid-gesture AX write failed (\(error.rawValue)) — ending the gesture")
        state.withLock { state in
            state.isEnded = true
            state.isDirty = false
            state.isDraining = false
        }
        restoreEnhancedUIIfNeeded()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onInvalidated?(error) }
        }
    }

    /// Runs on `axQueue` so the restore lands after any in-flight write.
    private func restoreEnhancedUIIfNeeded() {
        targetWindow.restoreEnhancedUIIfNeeded()
    }
}
