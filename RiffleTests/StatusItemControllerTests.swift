import Foundation
import XCTest
@testable import Riffle

final class StatusItemControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()

        suiteName = "StatusItemControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil

        super.tearDown()
    }

    func testInputCaptureFailureDisablesRiffleOnce() {
        var disabledStateChanges = 0
        let controller = StatusItemController(preferences: Preferences(defaults: defaults)) {
            disabledStateChanges += 1
        }

        controller.disable()
        controller.disable()

        XCTAssertTrue(controller.isDisabled)
        XCTAssertEqual(disabledStateChanges, 1)
    }
}
