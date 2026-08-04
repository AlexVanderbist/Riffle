import XCTest
@testable import Riffle

final class ResizeMathTests: XCTestCase {
    func testResizeDisplayUsesTheDisplayContainingTheWindowCenter() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)

        let selected = ResizeDisplay.bounds(
            for: CGRect(x: 750, y: 100, width: 500, height: 400),
            cursor: CGPoint(x: 1500, y: 300),
            among: [left, right]
        )

        XCTAssertEqual(selected, left)
    }

    func testResizeDisplayFallsBackToTheDisplayContainingTheCursor() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1200, y: 0, width: 1000, height: 800)

        let selected = ResizeDisplay.bounds(
            for: CGRect(x: 1000, y: -600, width: 100, height: 100),
            cursor: CGPoint(x: 1500, y: 300),
            among: [left, right]
        )

        XCTAssertEqual(selected, right)
    }

    func testResizeDisplayFallsBackToTheNearestActiveDisplay() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1200, y: 0, width: 1000, height: 800)

        let selected = ResizeDisplay.bounds(
            for: CGRect(x: 1100, y: -600, width: 100, height: 100),
            cursor: CGPoint(x: 1100, y: -400),
            among: [left, right]
        )

        XCTAssertEqual(selected, right)
    }

    func testMagnificationScalesAroundTheWindowCenter() {
        var resize = PendingResize(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        resize.apply(magnification: 0.5)

        XCTAssertEqual(resize.targetFrame, CGRect(x: 0, y: 125, width: 1000, height: 750))
    }

    func testShrinkingStopsAtA200PointShorterEdge() {
        var resize = PendingResize(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        resize.apply(magnification: -2)

        XCTAssertEqual(
            resize.targetFrame,
            CGRect(x: 366.6666666666667, y: 400, width: 266.66666666666663, height: 200)
        )
    }

    func testWindowBelowTheFloorCannotShrinkButIsNotEnlarged() {
        var resize = PendingResize(
            frame: CGRect(x: 100, y: 200, width: 180, height: 150),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )

        resize.apply(magnification: -0.5)

        XCTAssertEqual(resize.targetFrame, CGRect(x: 100, y: 200, width: 180, height: 150))
    }

    func testGrowthStopsBeforeEitherDimensionExceedsTheResizeDisplay() {
        var resize = PendingResize(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            displayBounds: CGRect(x: 0, y: 0, width: 900, height: 650)
        )

        resize.apply(magnification: 1)

        XCTAssertEqual(resize.targetFrame.width, 866.6666666666666, accuracy: 0.0001)
        XCTAssertEqual(resize.targetFrame.height, 650, accuracy: 0.0001)
        XCTAssertEqual(resize.targetFrame.midX, 500, accuracy: 0.0001)
        XCTAssertEqual(resize.targetFrame.midY, 500, accuracy: 0.0001)
    }

    func testAlreadyOversizedWindowCanShrinkButCannotGrow() {
        let frame = CGRect(x: -100, y: -100, width: 1200, height: 900)
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var outwardResize = PendingResize(frame: frame, displayBounds: display)
        var inwardResize = PendingResize(frame: frame, displayBounds: display)

        outwardResize.apply(magnification: 0.5)
        inwardResize.apply(magnification: -0.5)

        XCTAssertEqual(outwardResize.targetFrame, frame)
        XCTAssertEqual(inwardResize.targetFrame, CGRect(x: 50, y: 12.5, width: 900, height: 675))
    }

    func testAlreadyOversizedWindowCannotGrowAfterShrinkingWithinTheSameGesture() {
        var resize = PendingResize(
            frame: CGRect(x: -100, y: -100, width: 1200, height: 900),
            displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        resize.apply(magnification: -0.4)
        let acceptedTarget = resize.target
        resize.accept(to: acceptedTarget.frame, consuming: acceptedTarget)

        resize.apply(magnification: 0.2)

        XCTAssertEqual(resize.targetFrame, CGRect(x: 20, y: -10, width: 960, height: 720))
    }

    func testOversizedGrowthLockIgnoresShrinksThatWereNeverApplied() {
        var resize = PendingResize(
            frame: CGRect(x: -100, y: -100, width: 1200, height: 900),
            displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        resize.apply(magnification: -0.4)

        resize.apply(magnification: 0.2)

        XCTAssertEqual(resize.targetFrame, CGRect(x: -40, y: -55, width: 1080, height: 810))
    }

    func testRebaseContinuesFromTheFrameTheAppAccepted() {
        var resize = PendingResize(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        resize.apply(magnification: -1)
        let appliedTarget = resize.target
        resize.apply(magnification: -0.2)

        resize.accept(
            to: CGRect(x: 250, y: 312.5, width: 500, height: 375),
            consuming: appliedTarget
        )

        XCTAssertEqual(resize.targetFrame, CGRect(x: 275, y: 331.25, width: 450, height: 337.5))
    }

    func testAcceptedTargetKeepsGestureWideAccumulation() {
        var resize = PendingResize(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        resize.apply(magnification: 0.5)
        let firstTarget = resize.target

        resize.accept(to: firstTarget.frame, consuming: firstTarget)
        resize.apply(magnification: 0.5)

        XCTAssertEqual(resize.targetFrame, CGRect(x: -100, y: 50, width: 1200, height: 900))
    }
}
