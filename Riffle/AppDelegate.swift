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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
        permissionMonitor.start()
    }
}
