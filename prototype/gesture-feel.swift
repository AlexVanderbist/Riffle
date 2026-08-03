// ============================================================================
// PROTOTYPE — throwaway screen-edge harness for Riffle issue #11.
//
// Question: while moving a Target Window, should screen edges contain the
// pointer at its original grab point, or constrain the frame so a tunable
// minimum number of points remains visible on each axis? Toggle both rules
// live and watch where the pointer, grab point, and frame end up. This is
// deliberately throwaway code: keep the answer, discard the harness.
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
    enum EdgeRule: CustomStringConvertible {
        case pointer
        case minimumVisible

        var description: String {
            switch self {
            case .pointer: "pointer containment"
            case .minimumVisible: "minimum-visible frame constraint"
            }
        }
    }

    var gain: Double = 1.5        // window px per finger px on swipe — SETTLED
    var accel: Double = 1.2       // exponent on each swipe delta — under test
    var momentum = false          // fling keeps moving the window after lift — SETTLED: off
    var flipX = false             // extra flips on top of natural-scroll normalization — SETTLED: defaults correct
    var flipY = false
    var pinchGain: Double = 0.5   // resize factor = 1 + accumulated magnification * pinchGain (1.0 was too hot)
    var anchorCenter = true       // pinch anchor: window center (false = top-left)
    var exclusive = true          // pinch and swipe never act at the same time
    var cursorFollow = true       // warp the cursor along with the window while moving
    var smooth = 1.0              // fraction of remaining distance applied per write (1 = off)
    var edgeRule: EdgeRule = .pointer
    var minimumVisible: CGFloat = 100

    var edgeRuleDescription: String {
        switch edgeRule {
        case .pointer: "pointer containment"
        case .minimumVisible: "minimum \(Int(minimumVisible)) pt visible"
        }
    }

    var description: String {
        "gain \(gain) · accel \(accel) · momentum \(momentum ? "ON" : "off") · "
            + "flip x:\(flipX ? "ON" : "off") y:\(flipY ? "ON" : "off") · "
            + "pinchGain \(pinchGain) · anchor \(anchorCenter ? "center" : "top-left") · "
            + "exclusive \(exclusive ? "ON" : "off") · cursorFollow \(cursorFollow ? "ON" : "off") · "
            + "smooth \(smooth > 0 && smooth < 1 ? String(smooth) : "off") · "
            + "edge \(edgeRuleDescription)"
    }
}

let settings = Settings()

// MARK: - Pure display-topology geometry

struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
    let refreshRate: Double
}

struct DisplayTopology {
    let displays: [DisplayInfo]

    static func current() -> DisplayTopology {
        let byID = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(number.uint32Value), screen)
        })

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let displays = byID.map { id, screen in
            let cocoaVisible = screen.visibleFrame
            let visible = CGRect(
                x: cocoaVisible.minX,
                y: primaryHeight - cocoaVisible.maxY,
                width: cocoaVisible.width,
                height: cocoaVisible.height
            )
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                frame: CGDisplayBounds(id),
                visibleFrame: visible,
                scale: screen.backingScaleFactor,
                refreshRate: screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : 0
            )
        }.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX < rhs.frame.minX
        }
        return DisplayTopology(displays: displays)
    }

    var frames: [CGRect] { displays.map(\.frame) }

    func display(containing point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.insetBy(dx: -0.01, dy: -0.01).contains(point) }
    }

    // For each display, return the window-origin range that leaves the
    // requested number of points visible horizontally and vertically. If the
    // request is impossible, use the maximum visible amount that geometry can
    // provide. This is the fallback for tiny windows/displays and giant values.
    func allowedWindowOrigins(windowSize: CGSize, minimumVisible: CGFloat) -> [CGRect] {
        frames.map { display in
            let visibleWidth = min(max(0, minimumVisible), windowSize.width, display.width)
            let visibleHeight = min(max(0, minimumVisible), windowSize.height, display.height)
            return CGRect(
                x: display.minX - windowSize.width + visibleWidth,
                y: display.minY - windowSize.height + visibleHeight,
                width: display.width + windowSize.width - 2 * visibleWidth,
                height: display.height + windowSize.height - 2 * visibleHeight
            )
        }
    }

    func closestPoint(to point: CGPoint, in rects: [CGRect]) -> CGPoint {
        guard !rects.isEmpty else { return point }
        if rects.contains(where: { $0.insetBy(dx: -0.01, dy: -0.01).contains(point) }) {
            return point
        }

        return rects.map { rect in
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX),
                    y: min(max(point.y, rect.minY), rect.maxY))
        }.min { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y)
                < hypot(rhs.x - point.x, rhs.y - point.y)
        } ?? point
    }

    // Move along the segment only while it remains inside the connected union
    // of active displays. This allows transitions across shared display edges,
    // but cannot jump across the holes created by staggered arrangements.
    func containedTravel(from start: CGPoint, to end: CGPoint) -> CGPoint {
        containedTravel(from: start, to: end, through: frames)
    }

    func containedTravel(from start: CGPoint, to end: CGPoint, through rects: [CGRect]) -> CGPoint {
        guard !rects.isEmpty else { return start }
        if start == end { return start }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let intervals = rects.compactMap { segmentInterval(from: start, dx: dx, dy: dy, in: $0) }
            .sorted { lhs, rhs in lhs.lowerBound < rhs.lowerBound }

        var reachable = 0.0
        for interval in intervals {
            if interval.lowerBound > reachable + 0.000_001 { break }
            reachable = max(reachable, interval.upperBound)
            if reachable >= 1 { return end }
        }

        let safeT = max(0, reachable - 0.000_001)
        return CGPoint(x: start.x + dx * safeT, y: start.y + dy * safeT)
    }

    private func segmentInterval(
        from start: CGPoint,
        dx: CGFloat,
        dy: CGFloat,
        in rect: CGRect
    ) -> ClosedRange<CGFloat>? {
        var lower: CGFloat = 0
        var upper: CGFloat = 1

        func clip(origin: CGFloat, delta: CGFloat, min: CGFloat, max: CGFloat) -> Bool {
            if abs(delta) < 0.000_001 { return origin >= min && origin <= max }
            let a = (min - origin) / delta
            let b = (max - origin) / delta
            lower = Swift.max(lower, Swift.min(a, b))
            upper = Swift.min(upper, Swift.max(a, b))
            return lower <= upper
        }

        guard clip(origin: start.x, delta: dx, min: rect.minX, max: rect.maxX),
              clip(origin: start.y, delta: dy, min: rect.minY, max: rect.maxY) else {
            return nil
        }
        return lower...upper
    }
}

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
    var grabOffset = CGPoint.zero
    var targetPos = CGPoint.zero
    var targetCursor = CGPoint.zero
    var topology = DisplayTopology.current()
    var lastEdgeNote = "No move sampled yet"
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
            applyMove(dx: shaped(dx), dy: shaped(dy))
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
        topology = .current()
        grabOffset = CGPoint(x: location.x - startPos.x, y: location.y - startPos.y)
        targetPos = startPos
        targetCursor = location
        lastEdgeNote = "Grab offset (\(Int(grabOffset.x)), \(Int(grabOffset.y))) · \(settings.edgeRuleDescription)"
        startCursor = location
        renderPrototype()
    }

    func applyMove(dx: Double, dy: Double) {
        switch settings.edgeRule {
        case .pointer:
            let proposed = CGPoint(x: targetCursor.x + dx, y: targetCursor.y + dy)
            let contained = topology.containedTravel(from: targetCursor, to: proposed)
            targetCursor = contained
            targetPos = CGPoint(x: contained.x - grabOffset.x,
                                y: contained.y - grabOffset.y)
            lastEdgeNote = contained == proposed
                ? "Pointer and original grab point remain attached"
                : "Pointer contained by active display topology"

        case .minimumVisible:
            let allowedOrigins = topology.allowedWindowOrigins(
                windowSize: startSize,
                minimumVisible: settings.minimumVisible
            )
            let normalizedPos = topology.closestPoint(to: targetPos, in: allowedOrigins)
            let proposedPos = CGPoint(x: normalizedPos.x + dx, y: normalizedPos.y + dy)
            targetPos = topology.containedTravel(
                from: normalizedPos,
                to: proposedPos,
                through: allowedOrigins
            )

            let attachedCursor = CGPoint(x: targetPos.x + grabOffset.x,
                                         y: targetPos.y + grabOffset.y)
            let containedCursor = topology.containedTravel(from: targetCursor, to: attachedCursor)
            targetCursor = containedCursor
            let drift = hypot(containedCursor.x - attachedCursor.x,
                              containedCursor.y - attachedCursor.y)
            if drift > 0.5 {
                lastEdgeNote = String(
                    format: "Minimum %.0f pt visible · pointer detached %.0f pt from grab point",
                    settings.minimumVisible, drift
                )
            } else if targetPos == proposedPos {
                lastEdgeNote = "Minimum-visible rule inactive · pointer remains attached"
            } else {
                lastEdgeNote = "Frame contained · at least \(Int(settings.minimumVisible)) pt visible per axis"
            }
        }
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
        let edgeRule = settings.edgeRuleDescription
        // no final write: lifting the fingers freezes the window where it is
        axQueue.async { [self] in
            guard let win else { return }
            let actual = axPoint(win, kAXPositionAttribute)
            let actualCursor = CGEvent(source: nil)?.location
            let actualGrab = actual.map { CGPoint(x: $0.x + self.grabOffset.x,
                                                   y: $0.y + self.grabOffset.y) }
            let drift = if let actualCursor, let actualGrab {
                hypot(actualCursor.x - actualGrab.x, actualCursor.y - actualGrab.y)
            } else { CGFloat.zero }
            self.lastEdgeNote = String(
                format: "%@ · Δ(%.0f, %.0f), %d events/%d writes · grab drift %.0f pt%@",
                edgeRule, moved.x, moved.y, ev, self.writes, drift, self.writeStats
            )
            restoreEnhancedUI(appEl, wasOn: wasOn)
            DispatchQueue.main.async { renderPrototype() }
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
                    timedWrite(win: win, pos: writtenPos, size: nil, warp: targetCursor)
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
Hold Ctrl+Shift and two-finger swipe to move the Target Window.

  r         toggle pointer containment ↔ minimum-visible frame constraint
  v 100     points that must remain visible on each axis   [100]
  d         refresh the active display topology

  g 1.5     swipe gain: window px per finger px            [1.5 — settled]
  e 1.2     acceleration exponent per swipe delta          [1.2 — under test]
  m         toggle momentum glide after lift               [off — settled]
  f         flip swipe direction (both axes; fx / fy = one axis)
  p 0.4     pinch gain                                     [0.5]
  a         toggle pinch anchor: center ↔ top-left         [center]
  c         toggle cursor follows window while moving      [on]
  l 0.5     smoothing: fraction of remaining distance per  [off]
            AX write — evens out jumps on slow apps.
            l 0 or l 1 = off; 0.05 = maximum honey
  x         toggle exclusive move/resize                   [on]
  s         redraw current state
  q         quit

Try each rule from center and corner grab points, then push against the menu
bar, Dock, every outer edge, staggered-display gaps, and shared display edges.
Also try a window larger than one display. On mixed displays, cross between
different scale factors and refresh rates.
"""

func rectDescription(_ rect: CGRect) -> String {
    String(format: "%.0f,%.0f %.0f×%.0f", rect.minX, rect.minY, rect.width, rect.height)
}

func renderPrototype() {
    print("\u{001B}[2J\u{001B}[H", terminator: "")
    print("\u{001B}[1mRiffle screen-edge prototype\u{001B}[0m  \u{001B}[2mthrowaway · issue 11\u{001B}[0m")
    print("\n\u{001B}[1mCurrent state\u{001B}[0m")
    print("  edge rule    \(settings.edgeRuleDescription)")
    print("  gesture      \(harness.mode == .move ? "moving" : harness.mode == .resize ? "resizing (out of scope)" : "idle")")
    print("  Target Window \(harness.windowLabel)")
    print("  result       \(harness.lastEdgeNote)")

    print("\n\u{001B}[1mActive display topology\u{001B}[0m  \u{001B}[2mglobal points; full frame is the movement boundary\u{001B}[0m")
    for display in harness.topology.displays {
        let refresh = display.refreshRate > 0 ? "\(Int(display.refreshRate)) Hz" : "dynamic Hz"
        print("  \(display.name) [\(display.id)] frame \(rectDescription(display.frame))")
        print("    \u{001B}[2mvisible \(rectDescription(display.visibleFrame)) · \(display.scale)x · \(refresh)\u{001B}[0m")
    }

    print("\n\u{001B}[1mControls and exercise checklist\u{001B}[0m")
    print(help)
    print("\u{001B}[2mSettings: \(settings.description)\u{001B}[0m")
}

func handleCommand(_ line: String) {
    let parts = line.split(separator: " ")
    guard let cmd = parts.first else { return }
    let arg = parts.count > 1 ? Double(parts[1]) : nil
    switch cmd {
    case "g": if let v = arg { settings.gain = v }
    case "e": if let v = arg { settings.accel = v }
    case "v": if let v = arg { settings.minimumVisible = max(0, v) }
    case "p": if let v = arg { settings.pinchGain = v }
    case "m": settings.momentum.toggle()
    case "f": settings.flipX.toggle(); settings.flipY.toggle()
    case "fx": settings.flipX.toggle()
    case "fy": settings.flipY.toggle()
    case "a": settings.anchorCenter.toggle()
    case "c": settings.cursorFollow.toggle()
    case "l": if let v = arg { settings.smooth = v }
    case "x": settings.exclusive.toggle()
    case "r":
        if harness.mode == .move { harness.endMove(reason: "edge rule changed") }
        settings.edgeRule = settings.edgeRule == .pointer ? .minimumVisible : .pointer
        harness.lastEdgeNote = "Switched to \(settings.edgeRuleDescription)"
    case "d":
        harness.topology = .current()
        harness.lastEdgeNote = "Refreshed active display topology"
    case "s": break
    case "q":
        DispatchQueue.main.async { harness.cleanup(); exit(0) }
        return
    default:
        harness.lastEdgeNote = "Unknown command: \(cmd)"
        renderPrototype()
        return
    }
    renderPrototype()
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

renderPrototype()
CFRunLoopRun()
