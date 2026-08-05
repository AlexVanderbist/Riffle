import AppKit
import ApplicationServices

@MainActor
struct TargetWindowFronting {
    private let activateOwningApplication: @MainActor (AXUIElement) -> Void
    private let raiseWindow: @MainActor (AXUIElement) -> Void

    init() {
        activateOwningApplication = Self.activateOwningApplication
        raiseWindow = Self.raiseWindow
    }

    init(
        activateOwningApplication: @escaping @MainActor (AXUIElement) -> Void,
        raiseWindow: @escaping @MainActor (AXUIElement) -> Void
    ) {
        self.activateOwningApplication = activateOwningApplication
        self.raiseWindow = raiseWindow
    }

    func bringToFront(_ targetWindow: AXUIElement?, whenEnabled: Bool) {
        guard whenEnabled, let targetWindow else { return }

        activateOwningApplication(targetWindow)
        raiseWindow(targetWindow)
    }

    private static func activateOwningApplication(of targetWindow: AXUIElement) {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(targetWindow, &processIdentifier) == .success,
              let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return
        }

        application.activate(options: [])
    }

    private static func raiseWindow(_ targetWindow: AXUIElement) {
        AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
    }
}
