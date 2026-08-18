import AppKit
import os
import ServiceManagement

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let preferences: Preferences
    private let loginItem = SMAppService.mainApp
    private let disabledStateDidChange: () -> Void
    private let logger = Logger(subsystem: "com.alexvanderbist.Riffle", category: "status-menu")

    private(set) var isDisabled = false

    init(preferences: Preferences, disabledStateDidChange: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.preferences = preferences
        self.disabledStateDidChange = disabledStateDidChange

        super.init()

        let statusImage = NSImage(named: "RiffleStatusIcon")
        statusImage?.isTemplate = true
        statusImage?.accessibilityDescription = "Riffle"
        statusItem.button?.image = statusImage

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let disabledItem = NSMenuItem(
            title: "Disabled",
            action: #selector(toggleDisabled(_:)),
            keyEquivalent: ""
        )
        disabledItem.target = self
        disabledItem.state = isDisabled ? .on : .off
        menu.addItem(disabledItem)

        menu.addItem(.separator())

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

        let snappingItem = NSMenuItem(title: "Snapping", action: nil, keyEquivalent: "")
        let snappingMenu = NSMenu()
        snappingMenu.addItem(.sectionHeader(title: "While moving a window"))
        for gesture in SnapGesture.allCases {
            let item = NSMenuItem(
                title: gesture.menuTitle,
                action: #selector(toggleSnapGesture(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = gesture.rawValue
            item.image = NSImage(systemSymbolName: gesture.menuSymbolName, accessibilityDescription: nil)
            item.state = preferences.isSnapGestureEnabled(gesture) ? .on : .off
            snappingMenu.addItem(item)
        }
        snappingItem.submenu = snappingMenu
        menu.addItem(snappingItem)

        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = loginItem.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        let resetToDefaultsItem = NSMenuItem(
            title: "Reset to Defaults",
            action: #selector(resetToDefaults(_:)),
            keyEquivalent: ""
        )
        resetToDefaultsItem.target = self
        menu.addItem(resetToDefaultsItem)

        menu.addItem(.separator())

        let exitItem = NSMenuItem(
            title: "Exit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(exitItem)
    }

    func disable() {
        guard !isDisabled else { return }

        isDisabled = true
        disabledStateDidChange()
    }

    @objc private func toggleDisabled(_ sender: NSMenuItem) {
        isDisabled.toggle()
        sender.state = isDisabled ? .on : .off
        disabledStateDidChange()
    }

    @objc private func toggleModifier(_ sender: NSMenuItem) {
        guard let modifier = sender.representedObject as? ModifierChord.Modifier else {
            return
        }

        preferences.toggle(modifier)
        sender.state = preferences.modifierChord.contains(modifier) ? .on : .off
    }

    @objc private func toggleSnapGesture(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let gesture = SnapGesture(rawValue: rawValue) else {
            return
        }

        preferences.toggleSnapGesture(gesture)
        sender.state = preferences.isSnapGestureEnabled(gesture) ? .on : .off
    }

    @objc private func toggleBringTargetWindowToFront(_ sender: NSMenuItem) {
        preferences.toggleBringTargetWindowToFront()
        sender.state = preferences.bringsTargetWindowToFront ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            switch loginItem.status {
            case .enabled:
                try loginItem.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notFound, .notRegistered:
                try loginItem.register()
            @unknown default:
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            logger.error("Could not update Launch at Login: \(error.localizedDescription)")
        }

        sender.state = loginItem.status == .enabled ? .on : .off
    }

    @objc private func resetToDefaults(_ sender: NSMenuItem) {
        preferences.resetToDefaults()

        if loginItem.status != .notRegistered {
            do {
                try loginItem.unregister()
            } catch {
                logger.error("Could not disable Launch at Login: \(error.localizedDescription)")
            }
        }

        isDisabled = false
        disabledStateDidChange()
    }
}
