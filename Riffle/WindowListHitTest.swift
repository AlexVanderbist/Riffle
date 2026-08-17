import AppKit
import ApplicationServices

/// Fallback hit-test for apps whose Accessibility tree does not implement
/// `AXUIElementCopyElementAtPosition` (Telegram draws its UI with custom
/// views and returns `kAXErrorNotImplemented`). The Window Server still knows
/// which window is under the cursor, and such apps usually do expose their
/// windows through `kAXWindowsAttribute`, so we match the two by frame.
nonisolated enum WindowListHitTest {
    struct OnScreenWindow: Equatable {
        let pid: pid_t
        let bounds: CGRect
    }

    /// Frames are compared with this tolerance because AX and Window Server
    /// coordinates can differ by sub-point rounding.
    static let frameTolerance: CGFloat = 1.0

    /// Resolves the AX window under `location` using the on-screen window list.
    static func window(at location: CGPoint) -> AXUIElement? {
        guard let hit = topmostWindow(at: location, in: onScreenWindows()) else { return nil }

        let app = AXUIElementCreateApplication(hit.pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        let frames = windows.map { window -> CGRect? in
            guard let position = TargetWindow.position(of: window),
                  let size = TargetWindow.size(of: window) else { return nil }
            return CGRect(origin: position, size: size)
        }
        guard let index = matchingWindowIndex(for: hit.bounds, among: frames) else { return nil }
        return windows[index]
    }

    /// The frontmost normal-level window containing `location`. `windows` must
    /// be ordered front to back, as `CGWindowListCopyWindowInfo` returns them.
    static func topmostWindow(at location: CGPoint, in windows: [OnScreenWindow]) -> OnScreenWindow? {
        windows.first { $0.bounds.contains(location) }
    }

    /// The index of the AX frame matching the Window Server bounds, or nil
    /// when no frame is close enough. `nil` frames are AX windows whose
    /// geometry could not be read.
    static func matchingWindowIndex(for bounds: CGRect, among frames: [CGRect?]) -> Int? {
        frames.firstIndex { frame in
            guard let frame else { return false }
            return abs(frame.minX - bounds.minX) <= frameTolerance
                && abs(frame.minY - bounds.minY) <= frameTolerance
                && abs(frame.width - bounds.width) <= frameTolerance
                && abs(frame.height - bounds.height) <= frameTolerance
        }
    }

    /// Normal-level (layer 0) windows currently on screen, front to back.
    private static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return nil
            }
            return OnScreenWindow(pid: pid, bounds: bounds)
        }
    }
}
