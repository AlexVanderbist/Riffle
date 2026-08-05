import CoreGraphics
import Foundation
import os

/// A session-level active event tap on scroll and gesture events. The handler
/// returns nil to consume an event — that is the entire capture mechanism.
///
/// macOS disables active taps that respond too slowly (or on user request).
/// User-input disables are recovered automatically, but a timeout fails open
/// and leaves capture disabled so Riffle cannot interfere with system input.
final class GestureEventTap {
    var handler: ((CGEventType, CGEvent) -> Unmanaged<CGEvent>?)?
    var didTimeOut: (() -> Void)?

    static let gestureEventType: UInt32 = 29

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var hasFailedOpen = false
    private let logger = Logger(subsystem: "com.alexvanderbist.Riffle", category: "event-tap")

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }

        hasFailedOpen = false
        let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue) | (1 << Self.gestureEventType)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<GestureEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                // The tap's run loop source lives on the main run loop, so
                // events always arrive on the main thread.
                return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Could not create the scroll event tap")
            return
        }

        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        startWatchdog()
        logger.info("Scroll event tap started")
    }

    func stop() {
        guard let tap else { return }

        watchdog?.invalidate()
        watchdog = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        CFMachPortInvalidate(tap)
        self.tap = nil
        logger.info("Scroll event tap stopped")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            guard !hasFailedOpen else { return Unmanaged.passUnretained(event) }

            hasFailedOpen = true
            logger.fault("Event tap timed out — leaving capture disabled to preserve system input")
            DispatchQueue.main.async { [weak self] in
                self?.didTimeOut?()
            }

            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            logger.warning("Event tap was disabled by user input — re-enabled")
            return Unmanaged.passUnretained(event)
        }
        return handler?(type, event) ?? Unmanaged.passUnretained(event)
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      !self.hasFailedOpen,
                      let tap = self.tap,
                      !CGEvent.tapIsEnabled(tap: tap) else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
                self.logger.warning("Watchdog found the event tap disabled — re-enabled")
            }
        }
        timer.tolerance = 1.0
        // .common keeps the watchdog running while the status bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}
