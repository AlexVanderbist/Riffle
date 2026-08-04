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

    private let window: AXUIElement
    private let appElement: AXUIElement
    private let enhancedUIWasEnabled: Bool
    private let startPosition: CGPoint
    private let startCursor: CGPoint
    private let writeInterval: TimeInterval

    private struct GestureState {
        var targetPosition: CGPoint
        var isDirty = false
        var isDraining = false
        var isEnded = false
    }

    private let state: OSAllocatedUnfairLock<GestureState>
    private let axQueue = DispatchQueue(label: "com.alexvanderbist.Riffle.ax-writes", qos: .userInteractive)
    private static let logger = Logger(subsystem: "com.alexvanderbist.Riffle", category: "move-session")

    // AX calls into a hung app block until this timeout instead of wedging
    // the caller for the default several seconds.
    private static let axMessagingTimeout: Float = 0.25

    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    /// Hit-tests the window under `cursor` and prepares it for a Move Gesture.
    /// Returns nil when there is no window or it refuses to report its frame;
    /// the gesture is still consumed by the caller, it just moves nothing.
    static func begin(at cursor: CGPoint, writeInterval: TimeInterval) -> MoveWindowSession? {
        guard let window = windowElement(at: cursor) else {
            logger.info("No window under the cursor — move gesture targets nothing")
            return nil
        }
        guard let position = pointAttribute(of: window, kAXPositionAttribute) else {
            logger.warning("Target window refuses to report its position — move gesture targets nothing")
            return nil
        }

        AXUIElementSetMessagingTimeout(window, axMessagingTimeout)

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let appElement = AXUIElementCreateApplication(pid)

        // AXEnhancedUserInterface makes position writes animate to wrong places
        // (Chrome and friends); disable it for the gesture, restore after.
        let enhancedUIWasEnabled = boolAttribute(of: appElement, enhancedUserInterfaceAttribute as String)
        if enhancedUIWasEnabled {
            AXUIElementSetAttributeValue(appElement, enhancedUserInterfaceAttribute, kCFBooleanFalse)
        }

        return MoveWindowSession(
            window: window,
            appElement: appElement,
            enhancedUIWasEnabled: enhancedUIWasEnabled,
            startPosition: position,
            startCursor: cursor,
            writeInterval: writeInterval
        )
    }

    private init(
        window: AXUIElement,
        appElement: AXUIElement,
        enhancedUIWasEnabled: Bool,
        startPosition: CGPoint,
        startCursor: CGPoint,
        writeInterval: TimeInterval
    ) {
        self.window = window
        self.appElement = appElement
        self.enhancedUIWasEnabled = enhancedUIWasEnabled
        self.startPosition = startPosition
        self.startCursor = startCursor
        self.writeInterval = writeInterval
        self.state = OSAllocatedUnfairLock(initialState: GestureState(targetPosition: startPosition))
    }

    /// Accumulates a translation into the target position and kicks the worker
    /// if it is idle. Fast enough for the tap callback: no AX work happens here.
    func apply(_ translation: CGVector) {
        let shouldDrain = state.withLock { state -> Bool in
            guard !state.isEnded else { return false }
            state.targetPosition.x += translation.dx
            state.targetPosition.y += translation.dy
            state.isDirty = true
            guard !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        guard shouldDrain else { return }
        axQueue.async { [self] in drain() }
    }

    /// Ends the gesture: pending un-applied targets are dropped, never snapped
    /// to, and the target app's Enhanced UI setting is restored.
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

    // MARK: - Serial write worker

    private func drain() {
        while true {
            let target = state.withLock { state -> CGPoint? in
                guard state.isDirty, !state.isEnded else {
                    state.isDraining = false
                    return nil
                }
                state.isDirty = false
                return state.targetPosition
            }
            guard let target else { return }

            let writeStarted = CFAbsoluteTimeGetCurrent()
            let error = write(position: target)

            switch error {
            case .success:
                warpCursor(alongside: target)
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
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    /// The cursor moves along with the window, keeping the grab point stable.
    private func warpCursor(alongside position: CGPoint) {
        let warp = CGPoint(
            x: startCursor.x + position.x - startPosition.x,
            y: startCursor.y + position.y - startPosition.y
        )
        CGWarpMouseCursorPosition(warp)
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
        guard enhancedUIWasEnabled else { return }
        AXUIElementSetAttributeValue(appElement, Self.enhancedUserInterfaceAttribute, kCFBooleanTrue)
    }

    // MARK: - AX helpers

    /// Resolves the AX element under `location` (top-left-origin global
    /// coordinates) to its containing window.
    private static func windowElement(at location: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // Bound the hit-test too: it runs in the tap callback, and a hung app
        // under the cursor must not stall event delivery for seconds.
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &element) == .success,
              let element else { return nil }

        if stringAttribute(of: element, kAXRoleAttribute) == kAXWindowRole { return element }

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        return (windowRef as! AXUIElement)
    }

    private static func pointAttribute(of element: AXUIElement, _ name: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func stringAttribute(of element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func boolAttribute(of element: AXUIElement, _ name: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }
}
