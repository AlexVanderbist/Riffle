import CoreGraphics
import XCTest
@testable import Riffle

final class WindowListHitTestTests: XCTestCase {
    private typealias Window = WindowListHitTest.OnScreenWindow

    func testTopmostWindowPicksTheFirstWindowContainingThePoint() {
        let front = Window(pid: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let behind = Window(pid: 2, bounds: CGRect(x: 50, y: 50, width: 100, height: 100))

        XCTAssertEqual(WindowListHitTest.topmostWindow(at: CGPoint(x: 75, y: 75), in: [front, behind]), front)
        XCTAssertEqual(WindowListHitTest.topmostWindow(at: CGPoint(x: 125, y: 125), in: [front, behind]), behind)
    }

    func testTopmostWindowIsNilWhenNoWindowContainsThePoint() {
        let window = Window(pid: 1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertNil(WindowListHitTest.topmostWindow(at: CGPoint(x: 200, y: 200), in: [window]))
    }

    func testMatchingWindowIndexToleratesSubPointDifferences() {
        let bounds = CGRect(x: 1364, y: 709, width: 1014, height: 677)
        let frames: [CGRect?] = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            nil,
            CGRect(x: 1364.5, y: 708.5, width: 1014, height: 677.4),
        ]

        XCTAssertEqual(WindowListHitTest.matchingWindowIndex(for: bounds, among: frames), 2)
    }

    func testMatchingWindowIndexIsNilWhenFramesDiffer() {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let frames: [CGRect?] = [
            CGRect(x: 100, y: 100, width: 500, height: 402),
            CGRect(x: 103, y: 100, width: 500, height: 400),
        ]

        XCTAssertNil(WindowListHitTest.matchingWindowIndex(for: bounds, among: frames))
    }
}
