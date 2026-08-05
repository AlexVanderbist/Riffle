import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is unowned; this keeps the delegate alive for the app's lifetime.
    private static let shared = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    private var statusItemController: StatusItemController?
    private let permissionMonitor = AccessibilityPermissionMonitor()
    private let preferences = Preferences()
    private lazy var gestureController = GestureController(
        preferences: preferences,
        targetWindowFronting: TargetWindowFronting()
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests inject into this app as their host; don't prompt for
        // permissions or install the status item during a test run.
        guard NSClassFromString("XCTestCase") == nil else { return }

        statusItemController = StatusItemController(preferences: preferences) { [weak self] in
            self?.updateGestureCapture()
        }

        gestureController.onAXFailure = { [weak permissionMonitor] in
            permissionMonitor?.recheck()
        }
        gestureController.onEventTapTimeout = { [weak self] in
            self?.statusItemController?.disable()
        }
        permissionMonitor.trustDidChange = { [weak self] _ in
            self?.updateGestureCapture()
        }
        permissionMonitor.start()

        updateGestureCapture()
    }

    private func updateGestureCapture() {
        if permissionMonitor.isTrusted, statusItemController?.isDisabled == false {
            gestureController.start()

            return
        }

        gestureController.stop()
    }
}
