import XCTest
@testable import Riffle

final class StretchMathTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 2000, height: 1000)

    /// Separation change expressed in display points, undoing the feel gain.
    private func swipe(_ dx: CGFloat, _ dy: CGFloat) -> CGVector {
        CGVector(dx: dx / 2000 / StretchFeel.displayFractionPerTrackpad, dy: dy / 1000 / StretchFeel.displayFractionPerTrackpad)
    }

    func testHorizontalSwipeChangesOnlyTheWidth() {
        var stretch = PendingStretch(frame: CGRect(x: 800, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(200, 0))

        XCTAssertEqual(stretch.targetFrame, CGRect(x: 700, y: 300, width: 600, height: 400))
    }

    func testVerticalSwipeChangesOnlyTheHeight() {
        var stretch = PendingStretch(frame: CGRect(x: 800, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(0, 200))

        XCTAssertEqual(stretch.targetFrame, CGRect(x: 800, y: 200, width: 400, height: 600))
    }

    func testCenteredWindowGrowsEvenlyAroundTheDisplayCenter() {
        var stretch = PendingStretch(frame: CGRect(x: 800, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(400, 200))

        XCTAssertEqual(stretch.targetFrame, CGRect(x: 600, y: 200, width: 800, height: 600))
    }

    func testWindowAtTheLeftEdgeKeepsTouchingIt() {
        var stretch = PendingStretch(frame: CGRect(x: 0, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(400, 0))

        XCTAssertEqual(stretch.targetFrame, CGRect(x: 0, y: 300, width: 800, height: 400))
    }

    func testLeadingGapKeepsItsShareOfTheFreeSpace() {
        // Left gap 400, right gap 1200: the window sits one quarter of the way across.
        var stretch = PendingStretch(frame: CGRect(x: 400, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(400, 0))

        // Free space shrinks from 1600 to 1200; one quarter of it is 300.
        XCTAssertEqual(stretch.targetFrame, CGRect(x: 300, y: 300, width: 800, height: 400))
    }

    func testShrinkingKeepsTheShareToo() {
        var stretch = PendingStretch(frame: CGRect(x: 400, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(-200, 0))

        // Free space grows from 1600 to 1800; one quarter of it is 450.
        XCTAssertEqual(stretch.targetFrame, CGRect(x: 450, y: 300, width: 200, height: 400))
    }

    func testGrowthStopsAtTheDisplaySize() {
        var stretch = PendingStretch(frame: CGRect(x: 400, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(5000, 5000))

        XCTAssertEqual(stretch.targetFrame, display)
    }

    func testShrinkingStopsAtA200PointEdge() {
        var stretch = PendingStretch(frame: CGRect(x: 800, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(-5000, -5000))

        XCTAssertEqual(stretch.targetFrame, CGRect(x: 900, y: 400, width: 200, height: 200))
    }

    func testWindowAlreadySmallerThan200KeepsItsOwnMinimum() {
        var stretch = PendingStretch(frame: CGRect(x: 800, y: 300, width: 150, height: 100), displayBounds: display)

        stretch.apply(swipe(-5000, -5000))

        XCTAssertEqual(stretch.targetFrame.size, CGSize(width: 150, height: 100))
    }

    func testWindowWiderThanTheDisplayShrinksAroundItsCenterAndCannotGrow() {
        var stretch = PendingStretch(frame: CGRect(x: -500, y: 300, width: 3000, height: 400), displayBounds: display)

        stretch.apply(swipe(400, 0))
        XCTAssertEqual(stretch.targetFrame, CGRect(x: -500, y: 300, width: 3000, height: 400))

        stretch.apply(swipe(-1400, 0))
        XCTAssertEqual(stretch.targetFrame, CGRect(x: 0, y: 300, width: 2000, height: 400))
    }

    func testAcceptedFrameDifferentFromTargetRebasesPendingSwipe() {
        var stretch = PendingStretch(frame: CGRect(x: 800, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(-100, 0))
        let target = stretch.target
        XCTAssertEqual(target.frame.width, 300)

        // The app refuses to go below 350 wide and reports the frame it kept.
        stretch.accept(to: CGRect(x: 825, y: 300, width: 350, height: 400), consuming: target)
        XCTAssertEqual(stretch.targetFrame, CGRect(x: 825, y: 300, width: 350, height: 400))

        // Further shrinking starts from the accepted frame, not the refused one.
        stretch.apply(swipe(-50, 0))
        XCTAssertEqual(stretch.targetFrame.width, 300)
    }

    func testAcceptedTargetLeavesPendingSwipeAlone() {
        var stretch = PendingStretch(frame: CGRect(x: 800, y: 300, width: 400, height: 400), displayBounds: display)

        stretch.apply(swipe(200, 0))
        let target = stretch.target
        stretch.accept(to: target.frame, consuming: target)
        stretch.apply(swipe(200, 0))

        XCTAssertEqual(stretch.targetFrame, CGRect(x: 600, y: 300, width: 800, height: 400))
    }

    func testSpreadingVerticallyHeightensAndDisplaySizeSetsTheGain() {
        let translation = StretchFeel.translation(
            normalizedDelta: CGVector(dx: 0.5, dy: 0.25),
            displayBounds: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        XCTAssertEqual(translation.dx, 800 * StretchFeel.displayFractionPerTrackpad)
        XCTAssertEqual(translation.dy, 250 * StretchFeel.displayFractionPerTrackpad)
    }
}
