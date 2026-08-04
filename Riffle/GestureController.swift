import AppKit
import CoreGraphics

/// Routes move and resize input from one event tap into an exclusive gesture
/// latch and one window session at a time.
final class GestureController {
    /// Called when a gesture dies on a hard AX failure — a chance to re-check
    /// Accessibility permission faster than the system notification delivers it.
    var onAXFailure: (() -> Void)?

    private let tap = GestureEventTap()
    private var latch = GestureLatch()
    private var moveSession: MoveWindowSession?
    private var resizeSession: ResizeWindowSession?
    private var screenParametersObserver: NSObjectProtocol?
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    private var writeInterval: TimeInterval {
        let fastestRefresh = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        return 1.0 / Double(max(fastestRefresh, 1))
    }

    func start() {
        guard !tap.isRunning else { return }
        observeScreenParameterChanges()
        tap.handler = { [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(type: type, event: event)
        }
        tap.start()
    }

    func stop() {
        endSessions()
        latch = GestureLatch()
        tap.stop()
        stopObservingScreenParameterChanges()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type.rawValue == GestureEventTap.gestureEventType {
            return handleMagnify(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let chordMatches = preferences.modifierChord.matches(event.flags)
        var target = TargetWindowHit.noWindow
        let action = latch.handleScroll(
            isContinuous: isContinuous,
            scrollPhase: scrollPhase,
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            chordMatches: chordMatches,
            targetAllowsCapture: {
                target = TargetWindow.captureTarget(at: event.location)
                return target.allowsCapture
            }
        )

        switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .beginMove:
            endSessions()
            beginMoveSession(targeting: target.element, at: event.location)
            applyDeltas(of: event)
            return nil
        case .applyMove:
            applyDeltas(of: event)
            return nil
        case .liftFingers:
            endMoveSession()
            return nil
        case .finishStream:
            // The session normally ended at liftFingers; this is a backstop
            // for a stream that reaches momentum end without one.
            endMoveSession()
            return nil
        case .discard:
            return nil
        }
    }

    private func handleMagnify(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let appKitEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        guard appKitEvent.type == .magnify else {
            return latch.isCapturingMagnify ? nil : Unmanaged.passUnretained(event)
        }

        let phase = GestureLatch.MagnifyPhase(rawValue: appKitEvent.phase.rawValue)
        let chordMatches = preferences.modifierChord.matches(event.flags)
        var target = TargetWindowHit.noWindow
        let action = latch.handleMagnify(
            phase: phase,
            chordMatches: chordMatches,
            targetAllowsCapture: {
                target = TargetWindow.captureTarget(at: event.location)
                return target.allowsCapture
            }
        )

        switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .beginResize:
            endSessions()
            beginResizeSession(targeting: target.element, at: event.location)
            resizeSession?.apply(magnification: appKitEvent.magnification)
            return nil
        case .applyResize:
            resizeSession?.apply(magnification: appKitEvent.magnification)
            return nil
        case .liftFingers:
            endResizeSession()
            return nil
        case .discard:
            return nil
        }
    }

    private func beginMoveSession(targeting element: AXUIElement?, at cursor: CGPoint) {
        let session = MoveWindowSession.begin(
            targeting: element,
            at: cursor,
            writeInterval: writeInterval
        )
        session?.onInvalidated = { [weak self] error in
            self?.moveSession = nil
            self?.handleInvalidation(error)
        }
        moveSession = session
    }

    private func beginResizeSession(targeting element: AXUIElement?, at cursor: CGPoint) {
        let session = ResizeWindowSession.begin(
            targeting: element,
            at: cursor,
            writeInterval: writeInterval
        )
        session?.onInvalidated = { [weak self] error in
            self?.resizeSession = nil
            self?.handleInvalidation(error)
        }
        resizeSession = session
    }

    private func handleInvalidation(_ error: AXError) {
        if error == .apiDisabled {
            onAXFailure?()
        }
    }

    private func applyDeltas(of event: CGEvent) {
        guard let moveSession else { return }
        let isCurrentTopology = moveSession.apply(MoveFeel.translation(
            pointDeltaAxis1: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
            pointDeltaAxis2: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
            isDirectionInvertedFromDevice: NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? true
        ), cursor: event.location)

        if !isCurrentTopology {
            self.moveSession = nil
        }
    }

    private func endMoveSession() {
        moveSession?.end()
        moveSession = nil
    }

    private func endResizeSession() {
        resizeSession?.end()
        resizeSession = nil
    }

    private func endSessions() {
        endMoveSession()
        endResizeSession()
    }

    private func observeScreenParameterChanges() {
        guard screenParametersObserver == nil else { return }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endMoveSessionForTopologyChange()
            }
        }
    }

    private func stopObservingScreenParameterChanges() {
        guard let screenParametersObserver else { return }

        NotificationCenter.default.removeObserver(screenParametersObserver)
        self.screenParametersObserver = nil
    }

    private func endMoveSessionForTopologyChange() {
        moveSession?.endForTopologyChange()
        moveSession = nil
    }
}
