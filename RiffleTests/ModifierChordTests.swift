import XCTest
@testable import Riffle

final class ModifierChordTests: XCTestCase {
    let chord = ModifierChord.default

    func testMatchesExactChord() {
        XCTAssertTrue(chord.matches([.maskControl, .maskShift]))
    }

    func testRejectsMissingModifier() {
        XCTAssertFalse(chord.matches([.maskControl]))
        XCTAssertFalse(chord.matches([.maskShift]))
        XCTAssertFalse(chord.matches([]))
    }

    func testRejectsExtraModifier() {
        XCTAssertFalse(chord.matches([.maskControl, .maskShift, .maskCommand]))
        XCTAssertFalse(chord.matches([.maskControl, .maskShift, .maskAlternate]))
        XCTAssertFalse(chord.matches([.maskControl, .maskShift, .maskSecondaryFn]))
    }

    func testRejectsDifferentChord() {
        XCTAssertFalse(chord.matches([.maskCommand, .maskShift]))
    }

    func testIgnoresNonModifierFlags() {
        // Real events carry state bits (caps lock, non-coalesced, device-dependent
        // bits) that must not affect chord matching.
        var flags: CGEventFlags = [.maskControl, .maskShift, .maskAlphaShift, .maskNonCoalesced]
        flags.insert(CGEventFlags(rawValue: 0x20000000))
        XCTAssertTrue(chord.matches(flags))
    }
}
