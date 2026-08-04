import Foundation
import XCTest
@testable import Riffle

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()

        suiteName = "PreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil

        super.tearDown()
    }

    func testFirstLaunchDefaultsToControlAndShift() {
        let preferences = Preferences(defaults: defaults)

        XCTAssertTrue(preferences.modifierChord.matches([.maskControl, .maskShift]))
    }

    func testChordChangesPersistAcrossLaunches() {
        let preferences = Preferences(defaults: defaults)
        preferences.toggle(.command)
        preferences.toggle(.control)

        let relaunchedPreferences = Preferences(defaults: defaults)

        XCTAssertTrue(relaunchedPreferences.modifierChord.matches([.maskCommand, .maskShift]))
    }
}
