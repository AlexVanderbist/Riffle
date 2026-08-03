// ============================================================================
// PROTOTYPE — throwaway gesture-feel harness for Riffle issue #6.
//
// Moves the window under the cursor with Ctrl+Shift + two-finger swipe and
// resizes it with Ctrl+Shift + pinch. Every feel parameter is tunable live
// from this terminal while you gesture. Keep the answers, delete this code.
//
// Run:   swift prototype/gesture-feel.swift
// Needs: Accessibility permission for your terminal app, and
//        System Settings > Trackpad > Scroll & Zoom > "Zoom in or out" ON
//        (macOS generates no pinch events without it).
// ============================================================================

import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Live-tunable settings

final class Settings {
    var gain: Double = 1.5        // window px per finger px on swipe — SETTLED
    var accel: Double = 1.0       // exponent on each swipe delta — SETTLED: linear
    var momentum = false          // fling keeps moving the window after lift — SETTLED: off
    var flipX = false             // extra flips on top of natural-scroll normalization — SETTLED: defaults correct
    var flipY = false
    var pinchGain: Double = 0.5   // resize factor = 1 + accumulated magnification * pinchGain (1.0 was too hot)
    var anchorCenter = true       // pinch anchor: window center (false = top-left)
    var exclusive = true          // pinch and swipe never act at the same time
    var cursorFollow = true       // warp the cursor along with the window while moving
    var smooth = 1.0              // fraction of remaining distance applied per write (1 = off)

    var description: String {
        "gain \(gain) · accel \(accel) · momentum \(momentum ? "ON" : "off") · "
            + "flip x:\(flipX ? "ON" : "off") y:\(flipY ? "ON" : "off") · "
            + "pinchGain \(pinchGain) · anchor \(anchorCenter ? "center" : "top-left") · "
            + "exclusive \(exclusive ? "ON" : "off") · cursorFollow \(cursorFollow ? "ON" : "off") · "
            + "smooth \(smooth > 0 && smooth < 1 ? String(smooth) : "off")"
    }
}

let settings = Settings()

// MARK: - AX helpers (top-left-origin global coordinates throughout)

func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref
}

func axPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
    guard let ref = axValue(el, attr), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(ref as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func axSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
    guard let ref = axValue(el, attr), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(ref as! AXValue, .cgSize, &s) else { return nil }
    return s
}

func axSet(_ el: AXUIElement, _ attr: String, point: CGPoint) {
    var p = point
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, attr as CFString, v) }
}

func axSet(_ el: AXUIElement, _ attr: String, size: CGSize) {
    var s = size
    if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, attr as CFString, v) }
}

func windowUnderCursor(at location: CGPoint) -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &element) == .success,
          let element else { return nil }
    if (axValue(element, kAXRoleAttribute) as? String) == kAXWindowRole { return element }
    guard let ref = axValue(element, kAXWindowAttribute),
          CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    return (ref as! AXUIElement)
}

// MARK: - Gesture harness

final class Harness {
    enum Mode { case none, move, resize }

    var mode: Mode = .none
    var capturingScroll = false
    var capturingMagnify = false

    var window: AXUIElement?
    var appElement: AXUIElement?
    var enhancedUIWasOn = false
    var windowLabel = "?"
    var resizable = true

    var startPos = CGPoint.zero
    var startSize = CGSize.zero
    var startCursor = CGPoint.zero
    var targetPos = CGPoint.zero
    var accumMag = 0.0

    var events = 0
    var writes = 0            // touched only on axQueue
    var axWriteTotal = 0.0    // touched only on axQueue
    var axWriteMax = 0.0      // touched only on axQueue
    var dirty = false
    var draining = false
    var writtenPos = CGPoint.zero  // axQueue-only: last frame actually written
    var writtenSize = CGSize.zero
    let axQueue = DispatchQueue(label: "riffle.prototype.ax-writes")

    // MARK: Event routing

    func handle(type: CGEventType, event: CGEvent, tap: CFMachPort?) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            print("⚠️  event tap was disabled (\(type.rawValue)) — re-enabled")
            return Unmanaged.passUnretained(event)
        }
        if type == .scrollWheel { return handleScroll(event) }
        if type.rawValue == 29 { return handleGestureEvent(event) }
        return Unmanaged.passUnretained(event)
    }

    func modifiersHeld(_ event: CGEvent) -> Bool {
        event.flags.contains(.maskControl) && event.flags.contains(.maskShift)
    }

    // MARK: Swipe → move

    func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
            return Unmanaged.passUnretained(event)
        }
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        if phase == 1 { // began: the only place the capture decision is made
            if mode == .move { endMove(reason: "new gesture") }
            if modifiersHeld(event) {
                capturingScroll = true
                if mode == .resize && settings.exclusive {
                    // resizing owns the trackpad: swallow the swipe, don't move
                } else {
                    beginMove(at: event.location)
                }
            } else {
                capturingScroll = false
            }
        }

        guard capturingScroll else { return Unmanaged.passUnretained(event) }

        if mode == .move && (momentumPhase == 0 || settings.momentum) {
            let (dx, dy) = normalizedDeltas(event)
            targetPos.x += shaped(dx)
            targetPos.y += shaped(dy)
            events += 1
            requestWrite()
        }

        if phase == 4 || phase == 8 { // ended / cancelled — fingers lifted
            if mode == .move && !settings.momentum { endMove(reason: "fingers lifted") }
            // keep swallowing: a momentum tail may still be coming
        }
        if momentumPhase == 3 { // momentum end
            if mode == .move { endMove(reason: "momentum ended") }
            capturingScroll = false
        }
        return nil // swallow: the app under the cursor never scrolls
    }

    func normalizedDeltas(_ event: CGEvent) -> (Double, Double) {
        let d1 = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) // vertical
        let d2 = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) // horizontal
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? true
        // Normalize so the window follows the fingers regardless of the
        // "natural scrolling" preference; flips are the empirical correction.
        var dx = inverted ? d2 : -d2
        var dy = inverted ? d1 : -d1
        if settings.flipX { dx = -dx }
        if settings.flipY { dy = -dy }
        return (dx, dy)
    }

    func shaped(_ delta: Double) -> Double {
        let sign = delta < 0 ? -1.0 : 1.0
        return sign * pow(abs(delta), settings.accel) * settings.gain
    }

    func beginMove(at location: CGPoint) {
        guard grabWindow(at: location) else { return }
        mode = .move
        targetPos = startPos
        startCursor = location
        print("▶ MOVE   \(windowLabel)")
    }

    var writeStats: String {
        guard writes > 0 else { return "" }
        return String(format: " · AX write avg %.1f ms, max %.1f ms",
                      axWriteTotal / Double(writes) * 1000, axWriteMax * 1000)
    }

    func endMove(reason: String) {
        let win = window, appEl = appElement, wasOn = enhancedUIWasOn
        let moved = CGPoint(x: targetPos.x - startPos.x, y: targetPos.y - startPos.y)
        let ev = events
        // no final write: lifting the fingers freezes the window where it is
        axQueue.async { [self] in
            guard let win else { return }
            let actual = axPoint(win, kAXPositionAttribute)
            print(String(format: "■ MOVE   Δ(%.0f, %.0f) in %d events, %d AX writes (%@)%@%@",
                         moved.x, moved.y, ev, writes, reason,
                         actual.map { String(format: " → now at (%.0f, %.0f)", $0.x, $0.y) } ?? "",
                         writeStats))
            restoreEnhancedUI(appEl, wasOn: wasOn)
        }
        clearGesture()
    }

    // MARK: Pinch → resize

    func handleGestureEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        guard ns.type == .magnify else {
            // Other gesture frames of a captured pinch are swallowed too, so the
            // app under the cursor sees no partial gesture stream.
            return capturingMagnify ? nil : Unmanaged.passUnretained(event)
        }

        if ns.phase.contains(.began) {
            if mode == .resize { endResize(reason: "new gesture") }
            if modifiersHeld(event) {
                capturingMagnify = true
                if mode == .move && settings.exclusive {
                    // moving owns the trackpad: swallow the pinch, don't resize
                } else {
                    beginResize(at: event.location)
                }
            } else {
                capturingMagnify = false
            }
        }

        guard capturingMagnify else { return Unmanaged.passUnretained(event) }

        if mode == .resize {
            accumMag += Double(ns.magnification)
            events += 1
            requestWrite()
        }

        if ns.phase.contains(.ended) || ns.phase.contains(.cancelled) {
            if mode == .resize { endResize(reason: "fingers lifted") }
            capturingMagnify = false
        }
        return nil
    }

    func beginResize(at location: CGPoint) {
        guard grabWindow(at: location) else { return }
        if !resizable {
            print("✋ window \(windowLabel) is not resizable — pinch ignored")
            let appEl = appElement, wasOn = enhancedUIWasOn
            axQueue.async { [self] in restoreEnhancedUI(appEl, wasOn: wasOn) }
            clearGesture()
            return
        }
        mode = .resize
        accumMag = 0
        targetPos = startPos
        print("▶ RESIZE \(windowLabel)")
    }

    func targetSize() -> CGSize {
        let factor = max(0.1, 1 + accumMag * settings.pinchGain)
        return CGSize(width: max(120, startSize.width * factor),
                      height: max(90, startSize.height * factor))
    }

    func endResize(reason: String) {
        let win = window, appEl = appElement, wasOn = enhancedUIWasOn
        let size = targetSize()
        let ss = startSize, ev = events
        // no final write: lifting the fingers freezes the window where it is
        axQueue.async { [self] in
            guard let win else { return }
            let actual = axSize(win, kAXSizeAttribute)
            print(String(format: "■ RESIZE %.0f×%.0f → target %.0f×%.0f in %d events, %d AX writes (%@)%@%@",
                         ss.width, ss.height, size.width, size.height, ev, writes, reason,
                         actual.map { String(format: " → actual %.0f×%.0f", $0.width, $0.height) } ?? "",
                         writeStats))
            restoreEnhancedUI(appEl, wasOn: wasOn)
        }
        clearGesture()
    }

    // MARK: Shared window plumbing

    func grabWindow(at location: CGPoint) -> Bool {
        guard let win = windowUnderCursor(at: location) else {
            print("✋ no window under the cursor — gesture swallowed but ignored")
            return false
        }
        guard let pos = axPoint(win, kAXPositionAttribute),
              let size = axSize(win, kAXSizeAttribute) else {
            print("✋ window refuses to report its frame — gesture ignored")
            return false
        }
        window = win
        startPos = pos
        startSize = size
        events = 0
        dirty = false
        axQueue.async { [self] in
            writes = 0
            axWriteTotal = 0
            axWriteMax = 0
            writtenPos = pos
            writtenSize = size
        }
        AXUIElementSetMessagingTimeout(win, 0.25)

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(win, kAXSizeAttribute as CFString, &settable)
        resizable = settable.boolValue

        var pid: pid_t = 0
        AXUIElementGetPid(win, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let title = (axValue(win, kAXTitleAttribute) as? String) ?? "untitled"
        windowLabel = "\(appName) — “\(title)”  (\(Int(size.width))×\(Int(size.height)) @ \(Int(pos.x)),\(Int(pos.y)))"

        // AXEnhancedUserInterface makes position writes animate to wrong places
        // (VoiceOver/Chrome); disable for the gesture, restore after.
        let appEl = AXUIElementCreateApplication(pid)
        appElement = appEl
        enhancedUIWasOn = (axValue(appEl, "AXEnhancedUserInterface") as? Bool) ?? false
        if enhancedUIWasOn {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        return true
    }

    // AX writes are synchronous IPC into the target app (60+ ms on slow apps),
    // so they never run in the tap callback. The callback only updates the
    // target; the serial queue applies the LATEST target and skips everything
    // in between. A slow app lags by at most one write instead of replaying a
    // queued backlog after the fingers lift.
    func requestWrite() {
        dirty = true
        guard !draining else { return }
        draining = true
        axQueue.async { [self] in
            while true {
                guard let win = window, mode != .none else { break }
                dirty = false
                let raw = settings.smooth
                let s = (raw <= 0 || raw >= 1) ? 1.0 : max(raw, 0.05) // 0 and 1 both mean off
                var converged = true
                switch mode {
                case .move:
                    writtenPos.x += (targetPos.x - writtenPos.x) * s
                    writtenPos.y += (targetPos.y - writtenPos.y) * s
                    converged = abs(targetPos.x - writtenPos.x) < 0.5
                        && abs(targetPos.y - writtenPos.y) < 0.5
                    if converged { writtenPos = targetPos }
                    timedWrite(win: win, pos: writtenPos, size: nil, warp: warpPoint(for: writtenPos))
                case .resize:
                    let target = targetSize()
                    writtenSize.width += (target.width - writtenSize.width) * s
                    writtenSize.height += (target.height - writtenSize.height) * s
                    converged = abs(target.width - writtenSize.width) < 0.5
                        && abs(target.height - writtenSize.height) < 0.5
                    if converged { writtenSize = target }
                    timedWrite(win: win,
                               pos: settings.anchorCenter ? anchoredPos(for: writtenSize) : nil,
                               size: writtenSize, warp: nil)
                case .none:
                    break
                }
                if !dirty && converged { break }
            }
            draining = false
        }
    }

    func timedWrite(win: AXUIElement, pos: CGPoint?, size: CGSize?, warp: CGPoint?) {
        let start = CFAbsoluteTimeGetCurrent()
        if let pos { axSet(win, kAXPositionAttribute, point: pos) }
        if let size { axSet(win, kAXSizeAttribute, size: size) }
        if let warp {
            CGWarpMouseCursorPosition(warp)
            // reset the post-warp suppression interval so the gesture stream
            // keeps flowing uninterrupted
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        axWriteTotal += elapsed
        axWriteMax = max(axWriteMax, elapsed)
        writes += 1
    }

    func warpPoint() -> CGPoint? { warpPoint(for: targetPos) }

    func warpPoint(for pos: CGPoint) -> CGPoint? {
        guard settings.cursorFollow else { return nil }
        return CGPoint(x: startCursor.x + pos.x - startPos.x,
                       y: startCursor.y + pos.y - startPos.y)
    }

    func anchoredPos(for size: CGSize) -> CGPoint {
        CGPoint(x: startPos.x + (startSize.width - size.width) / 2,
                y: startPos.y + (startSize.height - size.height) / 2)
    }

    func clearGesture() {
        window = nil
        appElement = nil
        enhancedUIWasOn = false
        mode = .none
        dirty = false
    }

    func restoreEnhancedUI(_ appEl: AXUIElement?, wasOn: Bool) {
        if wasOn, let appEl {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    func cleanup() {
        if mode == .move { endMove(reason: "quit") }
        if mode == .resize { endResize(reason: "quit") }
        axQueue.sync {} // let the final write land before exit
    }
}

let harness = Harness()

// MARK: - Terminal command loop

let help = """
── Riffle gesture-feel prototype ──────────────────────────────────────────────
Hold Ctrl+Shift and two-finger swipe to MOVE, pinch to RESIZE the window
under the cursor. Tune live (type command + Enter):

  g 1.5     swipe gain: window px per finger px            [1.5 — settled]
  e 1.2     acceleration exponent per swipe delta          [1.0 — settled]
  m         toggle momentum glide after lift               [off — settled]
  f         flip swipe direction (both axes; fx / fy = one axis)
  p 0.4     pinch gain                                     [0.5]
  a         toggle pinch anchor: center ↔ top-left         [center]
  c         toggle cursor follows window while moving      [on]
  l 0.5     smoothing: fraction of remaining distance per  [off]
            AX write — evens out jumps on slow apps.
            l 0 or l 1 = off; 0.05 = maximum honey
  x         toggle exclusive move/resize                   [on]
  s         show current settings
  q         quit

If the window moves opposite to your fingers → f. If pinch does nothing,
enable System Settings > Trackpad > Scroll & Zoom > "Zoom in or out".
───────────────────────────────────────────────────────────────────────────────
"""

func handleCommand(_ line: String) {
    let parts = line.split(separator: " ")
    guard let cmd = parts.first else { return }
    let arg = parts.count > 1 ? Double(parts[1]) : nil
    switch cmd {
    case "g": if let v = arg { settings.gain = v }
    case "e": if let v = arg { settings.accel = v }
    case "p": if let v = arg { settings.pinchGain = v }
    case "m": settings.momentum.toggle()
    case "f": settings.flipX.toggle(); settings.flipY.toggle()
    case "fx": settings.flipX.toggle()
    case "fy": settings.flipY.toggle()
    case "a": settings.anchorCenter.toggle()
    case "c": settings.cursorFollow.toggle()
    case "l": if let v = arg { settings.smooth = v }
    case "x": settings.exclusive.toggle()
    case "s": break
    case "q":
        DispatchQueue.main.async { harness.cleanup(); exit(0) }
        return
    default:
        print(help)
        return
    }
    print("⚙️  \(settings.description)")
}

// MARK: - Boot

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    print("⏳ Grant Accessibility to your terminal app in System Settings →")
    print("   Privacy & Security → Accessibility, then this will start automatically…")
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 0.5) }
}

let gestureEventType: UInt32 = 29 // undocumented CGEvent type for trackpad gestures
let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue) | (1 << UInt64(gestureEventType))

var tapPort: CFMachPort?
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        harness.handle(type: type, event: event, tap: tapPort)
    },
    userInfo: nil
) else {
    print("❌ could not create the event tap — is Accessibility granted to your terminal?")
    exit(1)
}
tapPort = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { harness.cleanup(); exit(0) }
sigint.resume()

DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() { handleCommand(line.trimmingCharacters(in: .whitespaces)) }
}

print(help)
print("⚙️  \(settings.description)")
print("👂 listening — go grab a window…")
CFRunLoopRun()
