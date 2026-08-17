import CoreGraphics
import XCTest
@testable import Riffle

final class GestureEventTapTests: XCTestCase {
    // GestureEventTap gets a MainActor-isolated deinit from the project's
    // default actor isolation; deallocating one mid-test crashes in the Swift
    // runtime's isolated-deinit path. The app never deallocates its tap, so
    // keep test instances alive for the whole run instead.
    private static var retainedTaps: [GestureEventTap] = []

    private func makeTap() -> GestureEventTap {
        let tap = GestureEventTap()
        Self.retainedTaps.append(tap)
        return tap
    }

    private func scrollEvent() -> CGEvent {
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        )!
    }

    // A handler returning nil consumes the event — the callback must return
    // nil to the tap, not resurrect the event. This is Riffle's entire
    // capture mechanism.
    func testConsumingHandlerResultReachesTheTapCallback() {
        let tap = makeTap()
        tap.handler = { _, _ in nil }
        let event = scrollEvent()

        let result = tap.handle(type: .scrollWheel, event: event)

        XCTAssertTrue(result == nil, "A consumed event must stay consumed")
    }

    func testPassingHandlerResultReachesTheTapCallback() {
        let tap = makeTap()
        tap.handler = { _, event in Unmanaged.passUnretained(event) }
        let event = scrollEvent()

        let result = tap.handle(type: .scrollWheel, event: event)

        XCTAssertTrue(result?.takeUnretainedValue() === event)
    }

    func testMissingHandlerPassesTheEventThrough() {
        let tap = makeTap()
        let event = scrollEvent()

        let result = tap.handle(type: .scrollWheel, event: event)

        XCTAssertTrue(result?.takeUnretainedValue() === event)
    }
}
