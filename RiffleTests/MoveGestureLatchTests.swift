import XCTest
@testable import Riffle

final class MoveGestureLatchTests: XCTestCase {
    typealias Phase = MoveGestureLatch.ScrollPhase
    typealias Momentum = MoveGestureLatch.MomentumPhase

    var latch = MoveGestureLatch()

    private func handle(
        isContinuous: Bool = true,
        phase: Int64 = Phase.none,
        momentum: Int64 = Momentum.none,
        chord: Bool = false
    ) -> MoveGestureLatch.Action {
        latch.handle(isContinuous: isContinuous, scrollPhase: phase, momentumPhase: momentum, chordMatches: chord)
    }

    func testChordedStreamIsCapturedThroughMomentumEnd() {
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
        XCTAssertEqual(handle(phase: Phase.changed, chord: true), .applyMove)
        XCTAssertEqual(handle(phase: Phase.changed, chord: true), .applyMove)
        XCTAssertEqual(handle(phase: Phase.ended, chord: true), .liftFingers)
        XCTAssertEqual(handle(momentum: Momentum.begin), .discard)
        XCTAssertEqual(handle(momentum: Momentum.continuing), .discard)
        XCTAssertEqual(handle(momentum: Momentum.end), .finishStream)
        XCTAssertFalse(latch.isCapturing)
    }

    func testStreamWithoutChordPassesThroughEntirely() {
        XCTAssertEqual(handle(phase: Phase.began, chord: false), .passThrough)
        // Pressing the chord mid-stream must not hijack the gesture.
        XCTAssertEqual(handle(phase: Phase.changed, chord: true), .passThrough)
        XCTAssertEqual(handle(phase: Phase.ended, chord: true), .passThrough)
        XCTAssertEqual(handle(momentum: Momentum.begin), .passThrough)
        XCTAssertEqual(handle(momentum: Momentum.end), .passThrough)
    }

    func testReleasingChordMidGestureKeepsConsuming() {
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
        XCTAssertEqual(handle(phase: Phase.changed, chord: false), .applyMove)
        XCTAssertEqual(handle(phase: Phase.ended, chord: false), .liftFingers)
        XCTAssertEqual(handle(momentum: Momentum.begin, chord: false), .discard)
        XCTAssertEqual(handle(momentum: Momentum.end, chord: false), .finishStream)
    }

    func testLineBasedMouseWheelAlwaysPassesThrough() {
        XCTAssertEqual(handle(isContinuous: false, phase: Phase.none, chord: true), .passThrough)
        // Even while a trackpad gesture is latched.
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
        XCTAssertEqual(handle(isContinuous: false, phase: Phase.none, chord: true), .passThrough)
        XCTAssertEqual(handle(phase: Phase.changed, chord: true), .applyMove)
    }

    func testCancelledPhaseFreezesLikeFingerLift() {
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
        XCTAssertEqual(handle(phase: Phase.cancelled, chord: true), .liftFingers)
    }

    func testMomentumIsDiscardedNeverApplied() {
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
        XCTAssertEqual(handle(phase: Phase.ended, chord: true), .liftFingers)
        // A momentum frame that still carries deltas must not move the window.
        XCTAssertEqual(handle(phase: Phase.changed, momentum: Momentum.continuing), .discard)
    }

    func testNewBeganReDecidesAfterStreamWithoutMomentum() {
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
        XCTAssertEqual(handle(phase: Phase.ended, chord: true), .liftFingers)
        // No momentum tail arrived; the next stream makes a fresh decision.
        XCTAssertEqual(handle(phase: Phase.began, chord: false), .passThrough)
        XCTAssertEqual(handle(phase: Phase.changed, chord: false), .passThrough)
    }

    func testNewChordedBeganWhileLatchedBeginsANewMove() {
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
        XCTAssertEqual(handle(phase: Phase.changed, chord: true), .applyMove)
        XCTAssertEqual(handle(phase: Phase.began, chord: true), .beginMove)
    }
}
