import AppKit
import ApplicationServices
import os

/// Tracks Accessibility permission: prompts on launch when untrusted, polls until
/// granted, and re-checks when the system reports a permission change — so trust
/// transitions are picked up without a relaunch.
final class AccessibilityPermissionMonitor: NSObject {
    /// Called on every trust transition after `start()`, never for the initial state.
    var trustDidChange: ((Bool) -> Void)?

    private(set) var isTrusted = false

    // Undocumented but long-stable; fires when the Accessibility permission database
    // changes. After a grant stops the polling, this is what detects revocation
    // (besides recheck() calls from AX failure sites).
    private static let accessibilityAPIChangedNotification = Notification.Name("com.apple.accessibility.api")

    private var pollTimer: Timer?
    private let logger = Logger(subsystem: "com.alexvanderbist.Riffle", category: "permissions")

    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
        logger.info("Accessibility permission at launch: \(self.isTrusted ? "granted" : "not granted")")

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityAPIDidChange),
            name: Self.accessibilityAPIChangedNotification,
            object: nil
        )

        if !isTrusted {
            startPolling()
        }
    }

    /// Re-checks trust immediately. Call sites that hit an unexpected AX failure use
    /// this to detect revocation faster than the distributed notification delivers it.
    @objc func recheck() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }

        isTrusted = trusted
        if trusted {
            stopPolling()
        } else {
            startPolling()
        }

        logger.info("Accessibility permission \(trusted ? "granted" : "revoked")")
        trustDidChange?(trusted)
    }

    @objc private func accessibilityAPIDidChange() {
        // The notification can arrive before the permission database reflects the
        // change, so a delayed re-check is needed to read the new state.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(recheck), object: nil)
        perform(#selector(recheck), with: nil, afterDelay: 0.5)
    }

    private func startPolling() {
        guard pollTimer == nil else { return }

        let timer = Timer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(recheck),
            userInfo: nil,
            repeats: true
        )
        // .common keeps the poll running while the status bar menu is open, which
        // parks the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
