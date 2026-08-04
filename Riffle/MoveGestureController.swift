import AppKit
import CoreGraphics

/// Glues the pieces of the Move Gesture together: the scroll event tap feeds
/// each event through the latch, and the resulting actions drive one
/// `MoveWindowSession` per gesture.
final class MoveGestureController {
    /// Called when a gesture dies on a hard AX failure — a chance to re-check
    /// Accessibility permission faster than the system notification delivers it.
    var onAXFailure: (() -> Void)?

    private let tap = ScrollEventTap()
    private var latch = MoveGestureLatch()
    private var session: MoveWindowSession?
    private let chord = ModifierChord.default

    func start() {
        guard !tap.isRunning else { return }
        tap.handler = { [weak self] event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(event)
        }
        tap.start()
    }

    func stop() {
        endSession()
        latch = MoveGestureLatch()
        tap.stop()
    }

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let action = latch.handle(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            chordMatches: chord.matches(event.flags)
        )

        switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .beginMove:
            endSession()
            beginSession(at: event.location)
            applyDeltas(of: event)
            return nil
        case .applyMove:
            applyDeltas(of: event)
            return nil
        case .liftFingers:
            endSession()
            return nil
        case .finishStream:
            // The session normally ended at liftFingers; this is a backstop
            // for a stream that reaches momentum end without one.
            endSession()
            return nil
        case .discard:
            return nil
        }
    }

    private func beginSession(at cursor: CGPoint) {
        let fastestRefresh = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        let session = MoveWindowSession.begin(at: cursor, writeInterval: 1.0 / Double(max(fastestRefresh, 1)))
        session?.onInvalidated = { [weak self] error in
            self?.session = nil
            if error == .apiDisabled { self?.onAXFailure?() }
        }
        self.session = session
    }

    private func applyDeltas(of event: CGEvent) {
        guard let session else { return }
        session.apply(MoveFeel.translation(
            pointDeltaAxis1: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
            pointDeltaAxis2: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
            isDirectionInvertedFromDevice: NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? true
        ))
    }

    private func endSession() {
        session?.end()
        session = nil
    }
}
