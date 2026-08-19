import XCTest
@testable import Riffle

final class TwoFingerSpreadTests: XCTestCase {
    private var spread = TwoFingerSpread()

    private func touches(_ positions: [(CGFloat, CGFloat)]) -> [TrackpadTouch] {
        positions.enumerated().map { index, position in
            TrackpadTouch(id: index, isTouching: true, normalizedPosition: CGPoint(x: position.0, y: position.1))
        }
    }

    func testFirstSnapshotOnlyPrimes() {
        XCTAssertNil(spread.handle(touches: touches([(0.4, 0.5), (0.6, 0.5)])))
    }

    func testSpreadingHorizontallyReportsPositiveDX() {
        _ = spread.handle(touches: touches([(0.4, 0.5), (0.6, 0.5)]))
        let delta = spread.handle(touches: touches([(0.3, 0.5), (0.7, 0.5)]))

        XCTAssertEqual(delta?.dx ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(delta?.dy ?? 1, 0, accuracy: 1e-9)
    }

    func testPinchingVerticallyReportsNegativeDY() {
        _ = spread.handle(touches: touches([(0.5, 0.3), (0.5, 0.7)]))
        let delta = spread.handle(touches: touches([(0.5, 0.4), (0.5, 0.6)]))

        XCTAssertEqual(delta?.dx ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(delta?.dy ?? 0, -0.2, accuracy: 1e-9)
    }

    func testFingerOrderDoesNotMatter() {
        _ = spread.handle(touches: touches([(0.6, 0.5), (0.4, 0.5)]))
        let delta = spread.handle(touches: touches([(0.3, 0.5), (0.7, 0.5)]))

        XCTAssertEqual(delta?.dx ?? 0, 0.2, accuracy: 1e-9)
    }

    func testFramesWithoutTouchDataAreIgnored() {
        _ = spread.handle(touches: touches([(0.4, 0.5), (0.6, 0.5)]))
        XCTAssertNil(spread.handle(touches: []))
        let delta = spread.handle(touches: touches([(0.3, 0.5), (0.7, 0.5)]))

        XCTAssertEqual(delta?.dx ?? 0, 0.2, accuracy: 1e-9)
    }

    func testOtherFingerCountsResetTheTracker() {
        _ = spread.handle(touches: touches([(0.4, 0.5), (0.6, 0.5)]))
        XCTAssertNil(spread.handle(touches: touches([(0.4, 0.5)])))
        XCTAssertNil(spread.handle(touches: touches([(0.3, 0.5), (0.7, 0.5)])))
    }
}
