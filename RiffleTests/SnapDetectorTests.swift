import XCTest
@testable import Riffle

final class SnapDetectorTests: XCTestCase {
    private var detector = SnapDetector(enabledGestures: Set(SnapGesture.allCases))

    @discardableResult
    private func feed(
        _ dx: CGFloat,
        _ dy: CGFloat,
        movedX: Bool = true,
        movedY: Bool = true,
        at time: TimeInterval
    ) -> SnapLayout? {
        detector.observe(translation: CGVector(dx: dx, dy: dy), movedX: movedX, movedY: movedY, now: time)
    }

    // MARK: - Flick

    func testFlickRightOnLiftSnapsRightHalf() {
        feed(120, 0, at: 0.00)
        feed(120, 0, at: 0.03)

        XCTAssertEqual(detector.flickLayout(now: 0.05), .rightHalf)
    }

    func testFlickLeftOnLiftSnapsLeftHalf() {
        feed(-120, 0, at: 0.00)
        feed(-120, 0, at: 0.03)

        XCTAssertEqual(detector.flickLayout(now: 0.05), .leftHalf)
    }

    func testFlickUpSnapsMaximized() {
        feed(0, -120, at: 0.00)
        feed(0, -120, at: 0.03)

        XCTAssertEqual(detector.flickLayout(now: 0.05), .maximized)
    }

    func testFlickUpFromLeftHalfSnapsTopLeftQuarter() {
        detector = SnapDetector(enabledGestures: Set(SnapGesture.allCases), currentHalf: -1)
        feed(0, -120, at: 0.00)
        feed(0, -120, at: 0.03)

        XCTAssertEqual(detector.flickLayout(now: 0.05), .topLeftQuarter)
    }

    func testFlickDownFromRightHalfSnapsBottomRightQuarter() {
        detector = SnapDetector(enabledGestures: Set(SnapGesture.allCases), currentHalf: 1)
        feed(0, 120, at: 0.00)
        feed(0, 120, at: 0.03)

        XCTAssertEqual(detector.flickLayout(now: 0.05), .bottomRightQuarter)
    }

    func testFlickDownWithoutAHalfDoesNothing() {
        feed(0, 120, at: 0.00)
        feed(0, 120, at: 0.03)

        XCTAssertNil(detector.flickLayout(now: 0.05))
    }

    func testSlowTravelIsNotAFlick() {
        feed(120, 0, at: 0.00)
        feed(120, 0, at: 0.20)

        XCTAssertNil(detector.flickLayout(now: 0.21))
    }

    func testDiagonalFlickBelowDominanceDoesNothing() {
        feed(100, 100, at: 0.00)
        feed(100, 100, at: 0.03)

        XCTAssertNil(detector.flickLayout(now: 0.05))
    }

    func testFlickIsIgnoredWhenDisabled() {
        detector = SnapDetector(enabledGestures: [.edgePress, .cornerPress, .wiggle])
        feed(120, 0, at: 0.00)
        feed(120, 0, at: 0.03)

        XCTAssertNil(detector.flickLayout(now: 0.05))
    }

    func testFlickAfterResetDoesNothing() {
        feed(120, 0, at: 0.00)
        feed(120, 0, at: 0.03)
        detector.reset(currentHalf: 0)

        XCTAssertNil(detector.flickLayout(now: 0.05))
    }

    // MARK: - Edge and corner press

    func testPressIntoLeftEdgeSnapsLeftHalfAtThePressDistance() {
        XCTAssertNil(feed(-100, 0, movedX: false, at: 0.0))
        XCTAssertNil(feed(-100, 0, movedX: false, at: 0.1))
        XCTAssertEqual(feed(-100, 0, movedX: false, at: 0.2), .leftHalf)
    }

    func testPressIntoRightEdgeSnapsRightHalf() {
        feed(100, 0, movedX: false, at: 0.0)
        feed(100, 0, movedX: false, at: 0.1)

        XCTAssertEqual(feed(100, 0, movedX: false, at: 0.2), .rightHalf)
    }

    func testPressIntoTopEdgeSnapsMaximized() {
        feed(0, -100, movedY: false, at: 0.0)
        feed(0, -100, movedY: false, at: 0.1)

        XCTAssertEqual(feed(0, -100, movedY: false, at: 0.2), .maximized)
    }

    func testPressIntoBottomEdgeAloneDoesNothing() {
        feed(0, 100, movedY: false, at: 0.0)
        feed(0, 100, movedY: false, at: 0.1)

        XCTAssertNil(feed(0, 100, movedY: false, at: 0.2))
    }

    func testPressIntoTopEdgeWhileOnLeftHalfSnapsTopLeftQuarter() {
        detector = SnapDetector(enabledGestures: Set(SnapGesture.allCases), currentHalf: -1)
        feed(0, -100, movedY: false, at: 0.0)
        feed(0, -100, movedY: false, at: 0.1)

        XCTAssertEqual(feed(0, -100, movedY: false, at: 0.2), .topLeftQuarter)
    }

    func testPressIntoBottomEdgeWhileOnRightHalfSnapsBottomRightQuarter() {
        detector = SnapDetector(enabledGestures: Set(SnapGesture.allCases), currentHalf: 1)
        feed(0, 100, movedY: false, at: 0.0)
        feed(0, 100, movedY: false, at: 0.1)

        XCTAssertEqual(feed(0, 100, movedY: false, at: 0.2), .bottomRightQuarter)
    }

    func testSidewaysShareAboveThresholdTurnsATopPressIntoACorner() {
        feed(40, -100, movedY: false, at: 0.0)
        feed(40, -100, movedY: false, at: 0.1)

        XCTAssertEqual(feed(40, -100, movedY: false, at: 0.2), .topRightQuarter)
    }

    func testSidewaysShareBelowThresholdStaysAnEdgePress() {
        feed(30, -100, movedY: false, at: 0.0)
        feed(30, -100, movedY: false, at: 0.1)

        XCTAssertEqual(feed(30, -100, movedY: false, at: 0.2), .maximized)
    }

    func testSidewaysShareTurnsASidePressIntoACorner() {
        feed(-100, 40, movedX: false, at: 0.0)
        feed(-100, 40, movedX: false, at: 0.1)

        XCTAssertEqual(feed(-100, 40, movedX: false, at: 0.2), .bottomLeftQuarter)
    }

    func testPinnedOnBothAxesFiresAtTheCornerPressDistance() {
        XCTAssertNil(feed(-50, -50, movedX: false, movedY: false, at: 0.0))
        XCTAssertNil(feed(-50, -50, movedX: false, movedY: false, at: 0.1))
        XCTAssertEqual(feed(-50, -50, movedX: false, movedY: false, at: 0.2), .topLeftQuarter)
    }

    func testMovingOnAnAxisResetsItsPressure() {
        feed(-100, 0, movedX: false, at: 0.0)
        feed(-100, 0, movedX: false, at: 0.1)
        feed(-10, 0, movedX: true, at: 0.2)

        XCTAssertNil(feed(-100, 0, movedX: false, at: 0.3))
        XCTAssertNil(feed(-100, 0, movedX: false, at: 0.4))
        XCTAssertEqual(feed(-100, 0, movedX: false, at: 0.5), .leftHalf)
    }

    func testReversingThePushResetsPressure() {
        feed(-100, 0, movedX: false, at: 0.0)
        feed(-100, 0, movedX: false, at: 0.1)
        feed(100, 0, movedX: false, at: 0.2)

        XCTAssertNil(feed(100, 0, movedX: false, at: 0.3))
        XCTAssertEqual(feed(100, 0, movedX: false, at: 0.4), .rightHalf)
    }

    func testDisabledEdgePressStillLetsCornerPressFire() {
        detector = SnapDetector(enabledGestures: [.cornerPress])
        feed(-100, 0, movedX: false, at: 0.0)
        feed(-100, 0, movedX: false, at: 0.1)
        XCTAssertNil(feed(-100, 0, movedX: false, at: 0.2))

        detector = SnapDetector(enabledGestures: [.cornerPress])
        feed(-50, -50, movedX: false, movedY: false, at: 0.0)
        feed(-50, -50, movedX: false, movedY: false, at: 0.1)
        XCTAssertEqual(feed(-50, -50, movedX: false, movedY: false, at: 0.2), .topLeftQuarter)
    }

    func testDisabledCornerPressStillLetsEdgePressFire() {
        detector = SnapDetector(enabledGestures: [.edgePress])
        feed(-50, -50, movedX: false, movedY: false, at: 0.0)
        feed(-50, -50, movedX: false, movedY: false, at: 0.1)
        XCTAssertNil(feed(-50, -50, movedX: false, movedY: false, at: 0.2))

        detector = SnapDetector(enabledGestures: [.edgePress])
        feed(-100, 0, movedX: false, at: 0.0)
        feed(-100, 0, movedX: false, at: 0.1)
        XCTAssertEqual(feed(-100, 0, movedX: false, at: 0.2), .leftHalf)
    }

    func testQuarterReachedFromAHalfIsAnEdgePress() {
        detector = SnapDetector(enabledGestures: [.edgePress], currentHalf: -1)
        feed(0, -100, movedY: false, at: 0.0)
        feed(0, -100, movedY: false, at: 0.1)
        XCTAssertEqual(feed(0, -100, movedY: false, at: 0.2), .topLeftQuarter)

        detector = SnapDetector(enabledGestures: [.cornerPress], currentHalf: -1)
        feed(0, -100, movedY: false, at: 0.0)
        feed(0, -100, movedY: false, at: 0.1)
        XCTAssertNil(feed(0, -100, movedY: false, at: 0.2))
    }

    // MARK: - Wiggle

    func testAlternatingRunsWithinTheWindowSnapCentered() {
        XCTAssertNil(feed(30, 0, at: 0.0))
        XCTAssertNil(feed(-30, 0, at: 0.1))
        XCTAssertNil(feed(30, 0, at: 0.2))
        XCTAssertNil(feed(-30, 0, at: 0.3))
        XCTAssertNil(feed(30, 0, at: 0.4))
        XCTAssertEqual(feed(-30, 0, at: 0.5), .centered80)
    }

    func testRunsShorterThanTheRunLengthDoNotCount() {
        for i in 0..<12 {
            XCTAssertNil(feed(i.isMultiple(of: 2) ? 20 : -20, 0, at: Double(i) * 0.05))
        }
    }

    func testRunsOlderThanTheWindowExpire() {
        feed(30, 0, at: 0.0)
        feed(-30, 0, at: 0.1)
        feed(30, 0, at: 0.2)
        feed(-30, 0, at: 0.3)
        feed(30, 0, at: 0.4)

        XCTAssertNil(feed(-30, 0, at: 1.0))
    }

    func testWiggleResetsAfterFiring() {
        for i in 0..<6 {
            feed(i.isMultiple(of: 2) ? 30 : -30, 0, at: Double(i) * 0.1)
        }

        XCTAssertNil(feed(30, 0, at: 0.6))
        XCTAssertNil(feed(-30, 0, at: 0.7))
    }

    func testWiggleIsIgnoredWhenDisabled() {
        detector = SnapDetector(enabledGestures: [.flick, .edgePress, .cornerPress])
        for i in 0..<6 {
            XCTAssertNil(feed(i.isMultiple(of: 2) ? 30 : -30, 0, at: Double(i) * 0.1))
        }
    }

    // MARK: - Pinning

    func testAxisCountsAsMovedWhenThePositionChanged() {
        let pinned = SnapPinning.pinned(
            translation: CGVector(dx: 10, dy: 0),
            before: CGPoint(x: 0, y: 0),
            after: CGPoint(x: 10, y: 0),
            cursorEdge: (0, 0)
        )

        XCTAssertTrue(pinned.movedX)
    }

    func testAxisIsPinnedWhenThePositionDidNotChange() {
        let pinned = SnapPinning.pinned(
            translation: CGVector(dx: 10, dy: -5),
            before: CGPoint(x: 0, y: 0),
            after: CGPoint(x: 0, y: 0),
            cursorEdge: (0, 0)
        )

        XCTAssertFalse(pinned.movedX)
        XCTAssertFalse(pinned.movedY)
    }

    func testCursorAtTheDisplayEdgeInThePushDirectionCountsAsPinned() {
        let pinned = SnapPinning.pinned(
            translation: CGVector(dx: 10, dy: 0),
            before: CGPoint(x: 0, y: 0),
            after: CGPoint(x: 10, y: 0),
            cursorEdge: (1, 0)
        )

        XCTAssertFalse(pinned.movedX)
    }

    func testCursorAtTheOppositeEdgeDoesNotCountAsPinned() {
        let pinned = SnapPinning.pinned(
            translation: CGVector(dx: 10, dy: 0),
            before: CGPoint(x: 0, y: 0),
            after: CGPoint(x: 10, y: 0),
            cursorEdge: (-1, 0)
        )

        XCTAssertTrue(pinned.movedX)
    }

    func testZeroTranslationCountsAsMoved() {
        let pinned = SnapPinning.pinned(
            translation: .zero,
            before: CGPoint(x: 0, y: 0),
            after: CGPoint(x: 0, y: 0),
            cursorEdge: (1, 1)
        )

        XCTAssertTrue(pinned.movedX)
        XCTAssertTrue(pinned.movedY)
    }
}
