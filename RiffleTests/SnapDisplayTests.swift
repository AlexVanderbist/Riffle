import XCTest
@testable import Riffle

final class SnapDisplayTests: XCTestCase {
    private let left = CGRect(x: 0, y: 25, width: 1000, height: 775)
    private let right = CGRect(x: 1000, y: 0, width: 800, height: 600)

    func testCursorDisplayWinsOverTheWindowCenterDisplay() {
        let frame = SnapDisplay.visibleFrame(
            for: CGRect(x: 100, y: 100, width: 400, height: 300),
            cursor: CGPoint(x: 1200, y: 300),
            among: [left, right]
        )

        XCTAssertEqual(frame, right)
    }

    func testFallsBackToTheWindowCenterDisplay() {
        let frame = SnapDisplay.visibleFrame(
            for: CGRect(x: 1100, y: 100, width: 400, height: 300),
            cursor: CGPoint(x: -500, y: -500),
            among: [left, right]
        )

        XCTAssertEqual(frame, right)
    }

    func testFallsBackToTheNearestDisplay() {
        let frame = SnapDisplay.visibleFrame(
            for: CGRect(x: 2000, y: 100, width: 400, height: 300),
            cursor: CGPoint(x: -500, y: -500),
            among: [left, right]
        )

        XCTAssertEqual(frame, right)
    }

    func testCursorEdgeDetectsTheFourOuterEdges() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 1, y: 400), among: [display]).x, -1)
        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 998.5, y: 400), among: [display]).x, 1)
        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 400, y: 0), among: [display]).y, -1)
        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 400, y: 799), among: [display]).y, 1)
        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 999, y: 799), among: [display]).x, 1)
        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 999, y: 799), among: [display]).y, 1)
    }

    func testCursorEdgeIsZeroInsideTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let edge = SnapDisplay.cursorEdge(CGPoint(x: 400, y: 300), among: [display])

        XCTAssertEqual(edge.x, 0)
        XCTAssertEqual(edge.y, 0)
    }

    func testCursorEdgeIsZeroOnABoundarySharedWithAnotherDisplay() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 1000, height: 800)

        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 999, y: 400), among: [a, b]).x, 0)
        XCTAssertEqual(SnapDisplay.cursorEdge(CGPoint(x: 999, y: 799), among: [a, b]).y, 1)
    }
}
