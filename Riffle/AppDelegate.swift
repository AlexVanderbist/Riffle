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
    private let moveGestureController = MoveGestureController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests inject into this app as their host; don't prompt for
        // permissions or install the status item during a test run.
        guard NSClassFromString("XCTestCase") == nil else { return }

        statusItemController = StatusItemController()

        moveGestureController.onAXFailure = { [weak permissionMonitor] in
            permissionMonitor?.recheck()
        }
        permissionMonitor.trustDidChange = { [weak moveGestureController] trusted in
            if trusted {
                moveGestureController?.start()
            } else {
                moveGestureController?.stop()
            }
        }
        permissionMonitor.start()
        if permissionMonitor.isTrusted {
            moveGestureController.start()
        }
    }
}
