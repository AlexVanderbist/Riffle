import XCTest
@testable import Riffle

final class MoveGeometryTests: XCTestCase {
    func testKeepsOneHundredPointsVisibleAtDisplayEdges() {
        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: -750, y: -550),
            windowSize: CGSize(width: 800, height: 600),
            cursor: .zero,
            topology: DisplayTopology(
                displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080)],
                mainDisplay: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            )
        )

        XCTAssertEqual(constrained, CGPoint(x: -700, y: -500))
    }

    func testKeepsAllOfASmallWindowVisible() {
        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 950, y: 770),
            windowSize: CGSize(width: 80, height: 60),
            cursor: .zero,
            topology: DisplayTopology(
                displays: [CGRect(x: 0, y: 0, width: 1000, height: 800)],
                mainDisplay: CGRect(x: 0, y: 0, width: 1000, height: 800)
            )
        )

        XCTAssertEqual(constrained, CGPoint(x: 920, y: 740))
    }

    func testMovesFreelyOntoAnotherDisplay() throws {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let topology = DisplayTopology(displays: [left, right], mainDisplay: left)

        let transition = try XCTUnwrap(MoveGeometry.constrain(
            origin: CGPoint(x: 1200, y: 200),
            from: CGPoint(x: 100, y: 200),
            windowSize: CGSize(width: 500, height: 400),
            cursor: CGPoint(x: 1500, y: 300),
            topology: topology
        ))
        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 1200, y: 200),
            from: transition,
            windowSize: CGSize(width: 500, height: 400),
            cursor: CGPoint(x: 1500, y: 300),
            topology: topology
        )

        XCTAssertEqual(constrained, CGPoint(x: 1200, y: 200))
    }

    func testEqualProjectionsPreferTheDisplayContainingThePointer() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1200, y: 0, width: 1000, height: 800)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 1050, y: 200),
            windowSize: CGSize(width: 100, height: 100),
            cursor: CGPoint(x: 1300, y: 300),
            topology: DisplayTopology(displays: [left, right], mainDisplay: left)
        )

        XCTAssertEqual(constrained, CGPoint(x: 1200, y: 200))
    }

    func testSmallDisplayMustRemainEntirelyCoveredByTheWindow() {
        let display = CGRect(x: 100, y: 200, width: 50, height: 80)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 0, y: 500),
            windowSize: CGSize(width: 80, height: 200),
            cursor: .zero,
            topology: DisplayTopology(displays: [display], mainDisplay: display)
        )

        XCTAssertEqual(constrained, CGPoint(x: 70, y: 200))
    }

    func testInvalidOriginProjectsToTheNearestValidOrigin() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: -550, y: 300),
            windowSize: CGSize(width: 600, height: 400),
            cursor: CGPoint(x: 20, y: 350),
            topology: DisplayTopology(displays: [display], mainDisplay: display)
        )

        XCTAssertEqual(constrained, CGPoint(x: -500, y: 300))
    }

    func testEqualProjectionsFallBackToTheMainDisplay() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1200, y: 0, width: 1000, height: 800)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 1050, y: 200),
            windowSize: CGSize(width: 100, height: 100),
            cursor: CGPoint(x: 1100, y: -100),
            topology: DisplayTopology(displays: [right, left], mainDisplay: left)
        )

        XCTAssertEqual(constrained, CGPoint(x: 900, y: 200))
    }

    func testNoActiveDisplaysHasNoValidOrigin() {
        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 100, y: 200),
            windowSize: CGSize(width: 800, height: 600),
            cursor: .zero,
            topology: DisplayTopology(displays: [], mainDisplay: nil)
        )

        XCTAssertNil(constrained)
    }

    func testDoesNotJumpBetweenDisconnectedValidRegions() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 2000, y: 0, width: 1000, height: 800)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 2200, y: 200),
            from: CGPoint(x: 100, y: 200),
            windowSize: CGSize(width: 100, height: 100),
            cursor: CGPoint(x: 2500, y: 300),
            topology: DisplayTopology(displays: [left, right], mainDisplay: left)
        )

        XCTAssertEqual(constrained, CGPoint(x: 900, y: 200))
    }

    func testDoesNotCutAcrossAHoleInConnectedValidRegions() {
        let horizontal = CGRect(x: 0, y: 0, width: 2000, height: 500)
        let vertical = CGRect(x: 0, y: 0, width: 500, height: 2000)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 300, y: 1800),
            from: CGPoint(x: 1800, y: 300),
            windowSize: CGSize(width: 100, height: 100),
            cursor: CGPoint(x: 300, y: 1900),
            topology: DisplayTopology(
                displays: [horizontal, vertical],
                mainDisplay: horizontal
            )
        )

        XCTAssertEqual(constrained, CGPoint(x: 300, y: 400))
    }

    func testReversingAtAnEdgeMovesImmediatelyWithoutConsumingHiddenOvershoot() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var move = PendingMove(
            frame: CGRect(x: 0, y: 200, width: 800, height: 600),
            cursor: CGPoint(x: 100, y: 300),
            topology: DisplayTopology(displays: [display], mainDisplay: display)
        )
        move.apply(CGVector(dx: -1000, dy: 0), cursor: CGPoint(x: 100, y: 300))
        let edge = try XCTUnwrap(move.target)
        move.accept(edge)

        move.apply(CGVector(dx: 10, dy: 0), cursor: CGPoint(x: 0, y: 300))

        XCTAssertEqual(move.target?.position.x, -690)
    }

    func testInvalidStartContinuesFromItsFirstProjectedPosition() throws {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var move = PendingMove(
            frame: CGRect(x: -550, y: 200, width: 600, height: 400),
            cursor: CGPoint(x: 20, y: 300),
            topology: DisplayTopology(displays: [display], mainDisplay: display)
        )
        move.apply(CGVector(dx: 1, dy: 0), cursor: CGPoint(x: 20, y: 300))
        let recovered = try XCTUnwrap(move.target)
        move.accept(recovered)

        move.apply(CGVector(dx: 10, dy: 0), cursor: CGPoint(x: 21, y: 300))

        XCTAssertEqual(move.target?.position.x, -490)
    }

    func testRebasePreservesDeltasThatArriveDuringAWindowWrite() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var move = PendingMove(
            frame: CGRect(x: 0, y: 200, width: 800, height: 600),
            cursor: CGPoint(x: 100, y: 300),
            topology: DisplayTopology(displays: [display], mainDisplay: display)
        )
        move.apply(CGVector(dx: -1000, dy: 0), cursor: CGPoint(x: 100, y: 300))
        let inFlightTarget = try XCTUnwrap(move.target)

        move.apply(CGVector(dx: 20, dy: 0), cursor: CGPoint(x: 0, y: 300))
        move.accept(inFlightTarget)

        XCTAssertEqual(move.target?.position.x, -680)
    }

    func testKeepsTheWindowTopBelowTheMenuBar() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 100, y: -300),
            windowSize: CGSize(width: 800, height: 600),
            cursor: CGPoint(x: 200, y: 10),
            topology: DisplayTopology(displays: [display], mainDisplay: display, menuBarHeights: [25])
        )

        XCTAssertEqual(constrained, CGPoint(x: 100, y: 25))
    }

    func testDisplaysWithoutAMenuBarStillAllowTheTopEdgeToOverhang() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let constrained = MoveGeometry.constrain(
            origin: CGPoint(x: 100, y: -300),
            windowSize: CGSize(width: 800, height: 600),
            cursor: CGPoint(x: 200, y: 10),
            topology: DisplayTopology(displays: [display], mainDisplay: display, menuBarHeights: [0])
        )

        XCTAssertEqual(constrained, CGPoint(x: 100, y: -300))
    }

    func testReversingAtTheMenuBarMovesImmediatelyWithoutConsumingHiddenOvershoot() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var move = PendingMove(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            cursor: CGPoint(x: 300, y: 300),
            topology: DisplayTopology(displays: [display], mainDisplay: display, menuBarHeights: [25])
        )
        move.apply(CGVector(dx: 0, dy: -1000), cursor: CGPoint(x: 300, y: 300))
        let menuBar = try XCTUnwrap(move.target)
        XCTAssertEqual(menuBar.position.y, 25)
        move.accept(menuBar)

        move.apply(CGVector(dx: 0, dy: 10), cursor: CGPoint(x: 300, y: 0))

        XCTAssertEqual(move.target?.position.y, 35)
    }

    func testCursorStaysAtItsGrabOffsetWhenTheWindowIsStoppedByTheMenuBar() throws {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var move = PendingMove(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            cursor: CGPoint(x: 300, y: 300),
            topology: DisplayTopology(displays: [display], mainDisplay: display, menuBarHeights: [25])
        )
        move.apply(CGVector(dx: 0, dy: -1000), cursor: CGPoint(x: 300, y: 300))
        let menuBar = try XCTUnwrap(move.target)
        move.accept(menuBar)
        XCTAssertEqual(menuBar.targetCursorPosition, CGPoint(x: 300, y: 125))

        move.apply(CGVector(dx: 0, dy: 10), cursor: CGPoint(x: 300, y: 125))

        XCTAssertEqual(move.target?.targetCursorPosition, CGPoint(x: 300, y: 135))
    }
}
