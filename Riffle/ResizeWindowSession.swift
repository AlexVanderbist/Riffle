import AppKit
import ApplicationServices
import os

/// One Resize Gesture against one Target Window.
///
/// Magnification is accumulated without AX work on the tap callback. A serial
/// worker writes the latest coalesced frame and then rebases pending resize
/// state to the frame the app actually accepted.
nonisolated final class ResizeWindowSession: @unchecked Sendable {
    var onInvalidated: (@MainActor (AXError) -> Void)?

    private let targetWindow: TargetWindow
    private let writeInterval: TimeInterval

    private struct GestureState {
        var resize: PendingResize
        var isDirty = false
        var isDraining = false
        var isEnded = false
    }

    private let state: OSAllocatedUnfairLock<GestureState>
    private let axQueue = DispatchQueue(label: "com.alexvanderbist.Riffle.ax-resize-writes", qos: .userInteractive)
    private static let logger = Logger(subsystem: "com.alexvanderbist.Riffle", category: "resize-session")
    @MainActor
    static func begin(at cursor: CGPoint, writeInterval: TimeInterval) -> ResizeWindowSession? {
        guard let element = TargetWindow.element(at: cursor) else {
            logger.info("No window under the cursor — resize gesture targets nothing")
            return nil
        }
        guard let position = TargetWindow.position(of: element),
              let size = TargetWindow.size(of: element) else {
            logger.warning("Target window refuses to report its frame — resize gesture targets nothing")
            return nil
        }

        let targetWindow = TargetWindow(element: element)
        guard targetWindow.isResizable else {
            targetWindow.restoreEnhancedUIIfNeeded()
            logger.info("Target window is not resizable — resize gesture targets nothing")
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        guard let displayBounds = ResizeDisplay.bounds(
            for: frame,
            cursor: cursor,
            among: ResizeDisplay.activeBounds
        ) else {
            targetWindow.restoreEnhancedUIIfNeeded()
            logger.warning("No active Resize Display — resize gesture targets nothing")
            return nil
        }

        return ResizeWindowSession(
            targetWindow: targetWindow,
            resize: PendingResize(frame: frame, displayBounds: displayBounds),
            writeInterval: writeInterval
        )
    }

    private init(
        targetWindow: TargetWindow,
        resize: PendingResize,
        writeInterval: TimeInterval
    ) {
        self.targetWindow = targetWindow
        self.writeInterval = writeInterval
        state = OSAllocatedUnfairLock(initialState: GestureState(resize: resize))
    }

    func apply(magnification: Double) {
        let shouldDrain = state.withLock { state -> Bool in
            guard !state.isEnded else { return false }
            state.resize.apply(magnification: magnification)
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
            let target = state.withLock { state -> PendingResize.Target? in
                guard state.isDirty, !state.isEnded else {
                    state.isDraining = false
                    return nil
                }
                state.isDirty = false
                return state.resize.target
            }
            guard let target else { return }

            let writeStarted = CFAbsoluteTimeGetCurrent()
            let result = write(frame: target.frame)

            switch result.error {
            case .success:
                state.withLock { state in
                    guard !state.isEnded else { return }
                    state.resize.accept(to: result.acceptedFrame ?? target.frame, consuming: target)
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
