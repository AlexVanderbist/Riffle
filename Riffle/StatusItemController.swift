import AppKit

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "Riffle"
        )

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuilt on every open so later tickets can compute per-open state (e.g. checkmarks).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let exitItem = NSMenuItem(
            title: "Exit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(exitItem)
    }
}
