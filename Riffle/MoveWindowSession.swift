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

    /// What the caller does with the session after `apply`.
    enum ApplyOutcome {
        case moving
        case ended
    }

    private struct GestureState {
        var move: PendingMove
        var isDirty = false
        var isDraining = false
        var isEnded = false
        var snapDetector: SnapDetector
        /// Cursor of the last applied translation; a Flick snaps around it.
        var lastCursor: CGPoint
        /// Translations before this time are dropped (Settle after a snap).
        var settleUntil: TimeInterval = 0
    }

    private struct SnapRebase {
        let layout: SnapLayout
        let frame: CGRect
        let cursor: CGPoint
    }

    private let targetWindow: TargetWindow
    private let displayTopology: DisplayTopology
    private let visibleFrames: [CGRect]
    private let startFrame: CGRect
    private let writeInterval: TimeInterval

    private let state: OSAllocatedUnfairLock<GestureState>
    private let writeGate = OSAllocatedUnfairLock(initialState: ())
    private let axQueue = DispatchQueue(label: "com.alexvanderbist.Riffle.ax-writes", qos: .userInteractive)
    private static let logger = Logger(subsystem: "com.alexvanderbist.Riffle", category: "move-session")

    /// Prepares the hit-tested window under `cursor` for a Move Gesture.
    /// Returns nil when there is no window or it refuses to report its frame;
    /// the gesture is still consumed by the caller, it just moves nothing.
    /// Snap Gestures are only armed for resizable windows.
    @MainActor
    static func begin(
        targeting element: AXUIElement?,
        at cursor: CGPoint,
        enabledSnapGestures: Set<SnapGesture>,
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

        let targetWindow = TargetWindow(element: element)
        var snapGestures = enabledSnapGestures
        if !snapGestures.isEmpty, !targetWindow.isResizable {
            logger.info("Target window is not resizable — snap gestures disarmed for this move")
            snapGestures = []
        }

        return MoveWindowSession(
            targetWindow: targetWindow,
            startFrame: CGRect(origin: position, size: size),
            startCursor: cursor,
            displayTopology: DisplayTopology.current,
            visibleFrames: SnapDisplay.visibleFrames,
            enabledSnapGestures: snapGestures,
            writeInterval: writeInterval
        )
    }

    private init(
        targetWindow: TargetWindow,
        startFrame: CGRect,
        startCursor: CGPoint,
        displayTopology: DisplayTopology,
        visibleFrames: [CGRect],
        enabledSnapGestures: Set<SnapGesture>,
        writeInterval: TimeInterval
    ) {
        self.targetWindow = targetWindow
        self.displayTopology = displayTopology
        self.visibleFrames = visibleFrames
        self.startFrame = startFrame
        self.writeInterval = writeInterval

        var currentHalf = 0
        if let visibleFrame = SnapDisplay.visibleFrame(for: startFrame, cursor: startCursor, among: visibleFrames) {
            currentHalf = SnapLayout.halfSide(of: startFrame, in: visibleFrame)
        }
        self.state = OSAllocatedUnfairLock(initialState: GestureState(
            move: PendingMove(frame: startFrame, cursor: startCursor, topology: displayTopology),
            snapDetector: SnapDetector(enabledGestures: enabledSnapGestures, currentHalf: currentHalf),
            lastCursor: startCursor
        ))
    }

    /// Accumulates a translation into the target position and kicks the worker
    /// if it is idle, or snaps when the translation completes a Snap Gesture.
    /// Fast enough for the tap callback: no AX work happens here.
    @MainActor
    func apply(_ translation: CGVector, cursor: CGPoint) -> ApplyOutcome {
        guard displayTopology == DisplayTopology.current else {
            endForTopologyChange()
            return .ended
        }
        guard !displayTopology.displays.isEmpty else { return .moving }

        let now = CFAbsoluteTimeGetCurrent()
        let cursorEdge = SnapDisplay.cursorEdge(cursor, among: displayTopology.displays)
        var rebase: SnapRebase?
        let shouldDrain = state.withLock { state -> Bool in
            guard !state.isEnded, now >= state.settleUntil else { return false }

            let before = state.move.target?.position
            state.move.apply(translation, cursor: cursor)
            state.lastCursor = cursor
            let after = state.move.target?.position

            if let before, let after {
                let pinned = SnapPinning.pinned(
                    translation: translation,
                    before: before,
                    after: after,
                    cursorEdge: cursorEdge
                )
                if let layout = state.snapDetector.observe(
                    translation: translation,
                    movedX: pinned.movedX,
                    movedY: pinned.movedY,
                    now: now
                ), let snapped = self.rebase(&state, onto: layout, cursor: cursor, now: now) {
                    rebase = snapped
                    return false
                }
            }

            state.isDirty = true
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }

        if let rebase {
            commitSnap(rebase, from: cursor)
        } else if shouldDrain {
            axQueue.async { [self] in drain() }
        }
        return .moving
    }

    /// Finger lift: a Flick snaps and ends the session, anything else just ends.
    func liftFingers() {
        let now = CFAbsoluteTimeGetCurrent()
        let flick = state.withLock { state -> (layout: SnapLayout, cursor: CGPoint)? in
            guard !state.isEnded, let layout = state.snapDetector.flickLayout(now: now) else { return nil }
            state.isEnded = true
            state.isDirty = false
            return (layout, state.lastCursor)
        }
        guard let flick else {
            end()
            return
        }
        snapAndEnd(flick.layout, cursor: flick.cursor)
    }

    // MARK: - Snapping

    private func snapFrame(for layout: SnapLayout, cursor: CGPoint) -> CGRect? {
        SnapDisplay.visibleFrame(for: startFrame, cursor: cursor, among: visibleFrames)
            .map { layout.frame(in: $0) }
    }

    /// Keeps the gesture alive on the snapped frame: the pending move restarts
    /// there, the cursor stays put when it is inside the frame (else it is
    /// pulled just inside), the detector forgets the push, and translations
    /// settle for a moment.
    private func rebase(
        _ state: inout GestureState,
        onto layout: SnapLayout,
        cursor: CGPoint,
        now: TimeInterval
    ) -> SnapRebase? {
        guard let frame = snapFrame(for: layout, cursor: cursor) else { return nil }

        let inset = frame.insetBy(
            dx: min(SnapFeel.cursorPullInset, frame.width / 4),
            dy: min(SnapFeel.cursorPullInset, frame.height / 4)
        )
        let newCursor = CGPoint(
            x: min(max(cursor.x, inset.minX), inset.maxX),
            y: min(max(cursor.y, inset.minY), inset.maxY)
        )
        state.move = PendingMove(frame: frame, cursor: newCursor, topology: displayTopology)
        state.snapDetector.reset(currentHalf: layout.halfSide)
        state.isDirty = false
        state.settleUntil = now + SnapFeel.settleTime

        return SnapRebase(layout: layout, frame: frame, cursor: newCursor)
    }

    /// Writes a mid-gesture snap. If the app clamps the frame (minimum size),
    /// the pending move is rebased onto what it actually accepted.
    private func commitSnap(_ rebase: SnapRebase, from cursor: CGPoint) {
        Self.logger.info("Snap \(rebase.layout.description) -> \(rebase.frame.origin.x),\(rebase.frame.origin.y) \(rebase.frame.width)x\(rebase.frame.height)")
        axQueue.async { [self] in
            let error = writeGate.withLock { _ -> AXError in
                guard state.withLock({ !$0.isEnded }) else { return .success }
                let error = write(frame: rebase.frame)
                if error == .success, rebase.cursor != cursor {
                    warpCursor(to: rebase.cursor)
                }
                return error
            }
            switch error {
            case .success:
                acceptActualFrame(after: rebase)
            case .invalidUIElement, .apiDisabled:
                invalidate(with: error)
            default:
                break
            }
        }
    }

    private func acceptActualFrame(after rebase: SnapRebase) {
        guard let position = TargetWindow.position(of: targetWindow.element),
              let size = TargetWindow.size(of: targetWindow.element) else { return }
        let actual = CGRect(origin: position, size: size)
        guard actual != rebase.frame else { return }

        let visibleFrame = SnapDisplay.visibleFrame(for: startFrame, cursor: rebase.cursor, among: visibleFrames)
        let currentHalf = visibleFrame.map { SnapLayout.halfSide(of: actual, in: $0) } ?? 0
        state.withLock { state in
            guard !state.isEnded, !state.isDirty else { return }
            state.move = PendingMove(frame: actual, cursor: rebase.cursor, topology: displayTopology)
            state.snapDetector.reset(currentHalf: currentHalf)
        }
    }

    /// A Flick on lift: writes the layout frame and finishes the session.
    private func snapAndEnd(_ layout: SnapLayout, cursor: CGPoint) {
        guard let frame = snapFrame(for: layout, cursor: cursor) else {
            finishEnding(wasAlreadyEnded: false)
            return
        }
        Self.logger.info("Snap \(layout.description) on lift -> \(frame.origin.x),\(frame.origin.y) \(frame.width)x\(frame.height)")
        axQueue.async { [self] in
            let error = writeGate.withLock { _ in write(frame: frame) }
            restoreEnhancedUIIfNeeded()
            if error == .invalidUIElement || error == .apiDisabled {
                invalidate(with: error)
            }
        }
    }

    /// Position is written on both sides of the size: apps clamp a position
    /// against the old size first, and again against the new one.
    private func write(frame: CGRect) -> AXError {
        let first = targetWindow.set(position: frame.origin)
        guard first == .success else { return first }
        let sizeError = targetWindow.set(size: frame.size)
        guard sizeError == .success else { return sizeError }
        return targetWindow.set(position: frame.origin)
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
