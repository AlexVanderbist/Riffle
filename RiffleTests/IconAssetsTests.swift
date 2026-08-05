import AppKit
import XCTest

final class IconAssetsTests: XCTestCase {
    func testStatusBarIconIsAvailableAsATemplateImage() throws {
        let image = try XCTUnwrap(NSImage(named: "RiffleStatusIcon"))

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    }
}
