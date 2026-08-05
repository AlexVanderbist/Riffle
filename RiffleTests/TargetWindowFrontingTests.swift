import ApplicationServices
import XCTest
@testable import Riffle

final class TargetWindowFrontingTests: XCTestCase {
    func testEnabledFrontingActivatesOwningApplicationThenRaisesTargetWindow() {
        let targetWindow = AXUIElementCreateSystemWide()
        var effects: [String] = []
        let fronting = TargetWindowFronting(
            activateOwningApplication: { element in
                XCTAssertEqual(element, targetWindow)
                effects.append("activate")
            },
            raiseWindow: { element in
                XCTAssertEqual(element, targetWindow)
                effects.append("raise")
            }
        )

        fronting.bringToFront(targetWindow, whenEnabled: true)

        XCTAssertEqual(effects, ["activate", "raise"])
    }

    func testDisabledFrontingLeavesFocusUntouched() {
        let targetWindow = AXUIElementCreateSystemWide()
        var effects: [String] = []
        let fronting = TargetWindowFronting(
            activateOwningApplication: { _ in effects.append("activate") },
            raiseWindow: { _ in effects.append("raise") }
        )

        fronting.bringToFront(targetWindow, whenEnabled: false)

        XCTAssertTrue(effects.isEmpty)
    }
}
