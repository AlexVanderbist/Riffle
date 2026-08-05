import AppKit

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let preferences: Preferences

    init(preferences: Preferences) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.preferences = preferences

        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "Riffle"
        )

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for modifier in ModifierChord.Modifier.allCases {
            let item = NSMenuItem(
                title: modifier.menuTitle,
                action: #selector(toggleModifier(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = modifier
            item.state = preferences.modifierChord.contains(modifier) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let bringTargetWindowToFrontItem = NSMenuItem(
            title: "Bring Window to Front",
            action: #selector(toggleBringTargetWindowToFront(_:)),
            keyEquivalent: ""
        )
        bringTargetWindowToFrontItem.target = self
        bringTargetWindowToFrontItem.state = preferences.bringsTargetWindowToFront ? .on : .off
        menu.addItem(bringTargetWindowToFrontItem)

        menu.addItem(.separator())

        let exitItem = NSMenuItem(
            title: "Exit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(exitItem)
    }

    @objc private func toggleModifier(_ sender: NSMenuItem) {
        guard let modifier = sender.representedObject as? ModifierChord.Modifier else {
            return
        }

        preferences.toggle(modifier)
        sender.state = preferences.modifierChord.contains(modifier) ? .on : .off
    }

    @objc private func toggleBringTargetWindowToFront(_ sender: NSMenuItem) {
        preferences.toggleBringTargetWindowToFront()
        sender.state = preferences.bringsTargetWindowToFront ? .on : .off
    }
}
