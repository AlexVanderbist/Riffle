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

    func testFirstLaunchBringsTargetWindowToFront() {
        let preferences = Preferences(defaults: defaults)

        XCTAssertTrue(preferences.bringsTargetWindowToFront)
    }

    func testBringTargetWindowToFrontChangesPersistAcrossLaunches() {
        let preferences = Preferences(defaults: defaults)
        preferences.toggleBringTargetWindowToFront()

        let relaunchedPreferences = Preferences(defaults: defaults)

        XCTAssertFalse(relaunchedPreferences.bringsTargetWindowToFront)
    }

    func testResetToDefaultsRestoresEveryStoredPreference() {
        let preferences = Preferences(defaults: defaults)
        preferences.toggle(.command)
        preferences.toggle(.control)
        preferences.toggleBringTargetWindowToFront()
        preferences.toggleSnapGesture(.wiggle)

        preferences.resetToDefaults()

        XCTAssertTrue(preferences.modifierChord.matches([.maskControl, .maskShift]))
        XCTAssertTrue(preferences.bringsTargetWindowToFront)
        XCTAssertTrue(preferences.isSnapGestureEnabled(.wiggle))

        let relaunchedPreferences = Preferences(defaults: defaults)
        XCTAssertTrue(relaunchedPreferences.modifierChord.matches([.maskControl, .maskShift]))
        XCTAssertTrue(relaunchedPreferences.bringsTargetWindowToFront)
        XCTAssertTrue(relaunchedPreferences.isSnapGestureEnabled(.wiggle))
    }

    func testFirstLaunchEnablesEverySnapGesture() {
        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.enabledSnapGestures, Set(SnapGesture.allCases))
    }

    func testSnapGestureToggleChangesPersistAcrossLaunches() {
        let preferences = Preferences(defaults: defaults)
        preferences.toggleSnapGesture(.flick)
        preferences.toggleSnapGesture(.cornerPress)

        let relaunchedPreferences = Preferences(defaults: defaults)

        XCTAssertFalse(relaunchedPreferences.isSnapGestureEnabled(.flick))
        XCTAssertFalse(relaunchedPreferences.isSnapGestureEnabled(.cornerPress))
        XCTAssertTrue(relaunchedPreferences.isSnapGestureEnabled(.edgePress))
        XCTAssertTrue(relaunchedPreferences.isSnapGestureEnabled(.wiggle))
    }
}
