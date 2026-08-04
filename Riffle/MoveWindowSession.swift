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
    }

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
            writeInterval: writeInterval
        )
    }

    private init(
        targetWindow: TargetWindow,
        startPosition: CGPoint,
        startCursor: CGPoint,
        windowSize: CGSize,
        displayTopology: DisplayTopology,
        writeInterval: TimeInterval
    ) {
        self.targetWindow = targetWindow
        self.displayTopology = displayTopology
        self.writeInterval = writeInterval
        self.state = OSAllocatedUnfairLock(initialState: GestureState(
            move: PendingMove(
                frame: CGRect(origin: startPosition, size: windowSize),
                cursor: startCursor,
                topology: displayTopology
            )
        ))
    }

    /// Accumulates a translation into the target position and kicks the worker
    /// if it is idle. Fast enough for the tap callback: no AX work happens here.
    @MainActor
    func apply(_ translation: CGVector, cursor: CGPoint) -> Bool {
        guard displayTopology == DisplayTopology.current else {
            endForTopologyChange()
            return false
        }
        guard !displayTopology.displays.isEmpty else { return true }

        let shouldDrain = state.withLock { state -> Bool in
            guard !state.isEnded else { return false }
            state.move.apply(translation, cursor: cursor)
            state.isDirty = true
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        guard shouldDrain else { return true }
        axQueue.async { [self] in drain() }

        return true
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

    /// The cursor follows the unconstrained gesture path. At a display edge,
    /// macOS contains it while the window remains at its constrained position.
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
