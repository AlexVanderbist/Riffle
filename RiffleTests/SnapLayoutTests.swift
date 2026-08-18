import XCTest
@testable import Riffle

final class SnapLayoutTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 25, width: 1000, height: 775)
    private let secondary = CGRect(x: 1000, y: 0, width: 800, height: 600)

    func testHalvesSplitTheVisibleFrameVertically() {
        XCTAssertEqual(SnapLayout.leftHalf.frame(in: visible), CGRect(x: 0, y: 25, width: 500, height: 775))
        XCTAssertEqual(SnapLayout.rightHalf.frame(in: visible), CGRect(x: 500, y: 25, width: 500, height: 775))
    }

    func testMaximizedIsTheVisibleFrame() {
        XCTAssertEqual(SnapLayout.maximized.frame(in: visible), visible)
    }

    func testQuartersTileTheVisibleFrame() {
        let quarters: [SnapLayout] = [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]
        let frames = quarters.map { $0.frame(in: visible) }

        XCTAssertEqual(frames[0], CGRect(x: 0, y: 25, width: 500, height: 387.5))
        XCTAssertEqual(frames[1], CGRect(x: 500, y: 25, width: 500, height: 387.5))
        XCTAssertEqual(frames[2], CGRect(x: 0, y: 412.5, width: 500, height: 387.5))
        XCTAssertEqual(frames[3], CGRect(x: 500, y: 412.5, width: 500, height: 387.5))
        XCTAssertEqual(frames.reduce(CGRect.null) { $0.union($1) }, visible)
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                XCTAssertTrue(a.intersection(b).isEmpty || a.intersection(b).width == 0 || a.intersection(b).height == 0)
            }
        }
    }

    func testCentered80IsScaledAndCentered() {
        let frame = SnapLayout.centered80.frame(in: visible)

        XCTAssertEqual(frame.width, 800, accuracy: 0.001)
        XCTAssertEqual(frame.height, 620, accuracy: 0.001)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, visible.midY, accuracy: 0.001)
    }

    func testFramesRespectTheVisibleFrameOrigin() {
        XCTAssertEqual(SnapLayout.leftHalf.frame(in: secondary), CGRect(x: 1000, y: 0, width: 400, height: 600))
        XCTAssertEqual(SnapLayout.bottomRightQuarter.frame(in: secondary), CGRect(x: 1400, y: 300, width: 400, height: 300))
    }

    func testHalfSideRecognizesLeftAndRightWithinTolerance() {
        XCTAssertEqual(SnapLayout.halfSide(of: CGRect(x: 0, y: 25, width: 500, height: 775), in: visible), -1)
        XCTAssertEqual(SnapLayout.halfSide(of: CGRect(x: 505, y: 20, width: 495, height: 780), in: visible), 1)
        XCTAssertEqual(SnapLayout.halfSide(of: CGRect(x: 0, y: 25, width: 507, height: 775), in: visible), 0)
    }

    func testHalfSideIsZeroForQuartersAndArbitraryFrames() {
        XCTAssertEqual(SnapLayout.halfSide(of: SnapLayout.topLeftQuarter.frame(in: visible), in: visible), 0)
        XCTAssertEqual(SnapLayout.halfSide(of: CGRect(x: 100, y: 100, width: 600, height: 400), in: visible), 0)
    }
}
