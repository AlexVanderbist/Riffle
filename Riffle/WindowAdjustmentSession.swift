import AppKit
import ApplicationServices
import os

/// A frame target and the pending input it consumed, so the session can rebase
/// after the app accepts a different frame.
nonisolated protocol PendingFrameTarget {
    var frame: CGRect { get }
}

/// Pure pending-frame state of one Resize Gesture (uniform or Directional Pinch): accumulates raw
/// gesture input and computes the frame to write next.
nonisolated protocol PendingFrameAdjustment {
    associatedtype Input
    associatedtype Target: PendingFrameTarget

    init(frame: CGRect, displayBounds: CGRect)
    var target: Target { get }
    mutating func apply(_ input: Input)
    mutating func accept(to acceptedFrame: CGRect, consuming target: Target)
}

typealias ResizeWindowSession = WindowAdjustmentSession<PendingResize>
typealias StretchWindowSession = WindowAdjustmentSession<PendingStretch>

/// One Resize Gesture (uniform or Directional Pinch) against one Target Window.
///
/// Gesture input is accumulated without AX work on the tap callback. A serial
/// worker writes the latest coalesced frame and then rebases the pending
/// adjustment to the frame the app actually accepted.
nonisolated final class WindowAdjustmentSession<Adjustment: PendingFrameAdjustment>: @unchecked Sendable {
    var onInvalidated: (@MainActor (AXError) -> Void)?

    private let targetWindow: TargetWindow
    private let writeInterval: TimeInterval

    private struct GestureState {
        var adjustment: Adjustment
        var isDirty = false
        var isDraining = false
        var isEnded = false
    }

    private let state: OSAllocatedUnfairLock<GestureState>
    private let axQueue = DispatchQueue(label: "com.alexvanderbist.Riffle.ax-frame-writes", qos: .userInteractive)
    private static var logger: Logger {
        Logger(subsystem: "com.alexvanderbist.Riffle", category: "adjustment-session")
    }

    @MainActor
    static func begin(
        targeting element: AXUIElement?,
        at cursor: CGPoint,
        writeInterval: TimeInterval
    ) -> WindowAdjustmentSession? {
        guard let element else {
            logger.info("No window under the cursor — gesture targets nothing")
            return nil
        }
        guard let position = TargetWindow.position(of: element),
              let size = TargetWindow.size(of: element) else {
            logger.warning("Target window refuses to report its frame — gesture targets nothing")
            return nil
        }

        let targetWindow = TargetWindow(element: element)
        guard targetWindow.isResizable else {
            targetWindow.restoreEnhancedUIIfNeeded()
            logger.info("Target window is not resizable — gesture targets nothing")
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        guard let displayBounds = ResizeDisplay.bounds(
            for: frame,
            cursor: cursor,
            among: ResizeDisplay.activeBounds
        ) else {
            targetWindow.restoreEnhancedUIIfNeeded()
            logger.warning("No active Resize Display — gesture targets nothing")
            return nil
        }

        return WindowAdjustmentSession(
            targetWindow: targetWindow,
            adjustment: Adjustment(frame: frame, displayBounds: displayBounds),
            writeInterval: writeInterval
        )
    }

    private init(
        targetWindow: TargetWindow,
        adjustment: Adjustment,
        writeInterval: TimeInterval
    ) {
        self.targetWindow = targetWindow
        self.writeInterval = writeInterval
        state = OSAllocatedUnfairLock(initialState: GestureState(adjustment: adjustment))
    }

    func apply(_ input: Adjustment.Input) {
        let shouldDrain = state.withLock { state -> Bool in
            guard !state.isEnded else { return false }
            state.adjustment.apply(input)
            state.isDirty = true
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        guard shouldDrain else { return }
        axQueue.async { [self] in drain() }
    }

    func end() {
        let wasEnded = state.withLock { state in
            let wasEnded = state.isEnded
            state.isEnded = true
            state.isDirty = false
            return wasEnded
        }
        guard !wasEnded else { return }

        axQueue.async { [self] in restoreEnhancedUIIfNeeded() }
    }

    private func drain() {
        while true {
            let target = state.withLock { state -> Adjustment.Target? in
                guard state.isDirty, !state.isEnded else {
                    state.isDraining = false
                    return nil
                }
                state.isDirty = false
                return state.adjustment.target
            }
            guard let target else { return }

            let writeStarted = CFAbsoluteTimeGetCurrent()
            let result = write(frame: target.frame)

            switch result.error {
            case .success:
                state.withLock { state in
                    guard !state.isEnded else { return }
                    state.adjustment.accept(to: result.acceptedFrame ?? target.frame, consuming: target)
                }
            case .invalidUIElement, .apiDisabled:
                invalidate(with: result.error)
                return
            default:
                break
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - writeStarted
            if elapsed < writeInterval {
                Thread.sleep(forTimeInterval: writeInterval - elapsed)
            }
        }
    }

    private func write(frame: CGRect) -> (error: AXError, acceptedFrame: CGRect?) {
        let positionError = targetWindow.set(position: frame.origin)
        guard positionError == .success else { return (positionError, nil) }

        let sizeError = targetWindow.set(size: frame.size)
        guard sizeError == .success else { return (sizeError, nil) }

        return (.success, targetWindow.frame ?? frame)
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

    private func restoreEnhancedUIIfNeeded() {
        targetWindow.restoreEnhancedUIIfNeeded()
    }
}
