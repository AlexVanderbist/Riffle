import XCTest
@testable import Riffle

final class MoveFeelTests: XCTestCase {
    // gain 1.5, exponent 1.2: 1.5 * 10^1.2 = 23.7734
    func testAppliesGainAndAccelerationPerAxis() {
        let t = MoveFeel.translation(pointDeltaAxis1: 0, pointDeltaAxis2: 10, isDirectionInvertedFromDevice: true)
        XCTAssertEqual(t.dx, 23.7734, accuracy: 0.001)
        XCTAssertEqual(t.dy, 0)

        let u = MoveFeel.translation(pointDeltaAxis1: 10, pointDeltaAxis2: 0, isDirectionInvertedFromDevice: true)
        XCTAssertEqual(u.dx, 0)
        XCTAssertEqual(u.dy, 23.7734, accuracy: 0.001)
    }

    func testUnitDeltaIsScaledByGainOnly() {
        let t = MoveFeel.translation(pointDeltaAxis1: 1, pointDeltaAxis2: -1, isDirectionInvertedFromDevice: true)
        XCTAssertEqual(t.dx, -1.5, accuracy: 0.0001)
        XCTAssertEqual(t.dy, 1.5, accuracy: 0.0001)
    }

    func testNaturalScrollingOffInvertsBothAxes() {
        let natural = MoveFeel.translation(pointDeltaAxis1: 4, pointDeltaAxis2: 7, isDirectionInvertedFromDevice: true)
        let classic = MoveFeel.translation(pointDeltaAxis1: 4, pointDeltaAxis2: 7, isDirectionInvertedFromDevice: false)
        XCTAssertEqual(classic.dx, -natural.dx, accuracy: 0.0001)
        XCTAssertEqual(classic.dy, -natural.dy, accuracy: 0.0001)
    }

    func testPreservesSignThroughAcceleration() {
        let t = MoveFeel.translation(pointDeltaAxis1: -10, pointDeltaAxis2: 0, isDirectionInvertedFromDevice: true)
        XCTAssertEqual(t.dy, -23.7734, accuracy: 0.001)
    }

    func testZeroDeltaStaysZero() {
        let t = MoveFeel.translation(pointDeltaAxis1: 0, pointDeltaAxis2: 0, isDirectionInvertedFromDevice: false)
        XCTAssertEqual(t.dx, 0)
        XCTAssertEqual(t.dy, 0)
    }
}
