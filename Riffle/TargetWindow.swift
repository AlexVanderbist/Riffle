import AppKit
import ApplicationServices

nonisolated enum TargetWindowHit: @unchecked Sendable {
    case noWindow
    case targetWindow(AXUIElement)
    case passThrough

    var element: AXUIElement? {
        guard case .targetWindow(let element) = self else { return nil }
        return element
    }

    var allowsCapture: Bool {
        if case .passThrough = self { return false }
        return true
    }
}

/// Cached Accessibility boundary for the Target Window and its owning app.
nonisolated final class TargetWindow: @unchecked Sendable {
    let element: AXUIElement

    private let appElement: AXUIElement
    private let enhancedUIWasEnabled: Bool
    private static let axMessagingTimeout: Float = 0.25
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString
    private static let fullScreenAttribute = "AXFullScreen"
    private static let systemUIBundleIdentifiers = [
        "com.apple.dock",
        "com.apple.WindowManager",
    ]
    private static let systemUIProcessNames = ["Dock", "WindowManager"]

    /// Hit-tests once and reports both the resolved window and whether Riffle
    /// may consume the gesture that began over it.
    static func captureTarget(at location: CGPoint) -> TargetWindowHit {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
        var element: AXUIElement?
        let hitTestError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(location.x),
            Float(location.y),
            &element
        )
        guard hitTestError == .success, let element else {
            if hitTestError == .noValue { return .noWindow }
            // Apps without an AX hit-test (Telegram) fail here; fall back to
            // the Window Server's idea of what is under the cursor.
            return windowListFallback(at: location)
        }

        guard let belongsToSystemUI = belongsToSystemUI(element) else { return .passThrough }
        guard !belongsToSystemUI else { return .passThrough }

        let window: AXUIElement
        if stringAttribute(of: element, kAXRoleAttribute) == kAXWindowRole {
            window = element
        } else {
            var windowRef: CFTypeRef?
            let windowError = AXUIElementCopyAttributeValue(
                element,
                kAXWindowAttribute as CFString,
                &windowRef
            )
            guard windowError == .success,
                  let windowRef,
                  CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
                if [.noValue, .attributeUnsupported].contains(windowError) { return .noWindow }
                return windowListFallback(at: location)
            }
            window = (windowRef as! AXUIElement)
        }

        guard allowsCapture(of: window) == true else { return .passThrough }
        return .targetWindow(window)
    }

    private static func windowListFallback(at location: CGPoint) -> TargetWindowHit {
        guard let window = WindowListHitTest.window(at: location) else { return .passThrough }
        guard allowsCapture(of: window) == true else { return .passThrough }
        return .targetWindow(window)
    }

    /// Full-screen and Split View windows are managed by macOS and must never
    /// be captured. The Dock and WindowManager own Stage Manager's sidebar and
    /// hidden-stage UI, which likewise are not Target Windows.
    private static func allowsCapture(of element: AXUIElement) -> Bool? {
        var fullScreenRef: CFTypeRef?
        let fullScreenError = AXUIElementCopyAttributeValue(
            element,
            fullScreenAttribute as CFString,
            &fullScreenRef
        )
        switch fullScreenError {
        case .success:
            guard let fullScreen = fullScreenRef as? Bool else { return nil }
            guard !fullScreen else { return false }
        case .noValue, .attributeUnsupported:
            break
        default:
            return nil
        }

        guard let belongsToSystemUI = belongsToSystemUI(element) else { return nil }
        return !belongsToSystemUI
    }

    private static func belongsToSystemUI(_ element: AXUIElement) -> Bool? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let application = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }

        if let bundleIdentifier = application.bundleIdentifier {
            return systemUIBundleIdentifiers.contains(bundleIdentifier)
        }
        if let processName = application.localizedName {
            return systemUIProcessNames.contains(processName)
        }
        return nil
    }

    init(element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, Self.axMessagingTimeout)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        appElement = AXUIElementCreateApplication(pid)
        enhancedUIWasEnabled = Self.boolAttribute(
            of: appElement,
            Self.enhancedUserInterfaceAttribute as String
        )
        if enhancedUIWasEnabled {
            AXUIElementSetAttributeValue(
                appElement,
                Self.enhancedUserInterfaceAttribute,
                kCFBooleanFalse
            )
        }
    }

    var position: CGPoint? { Self.pointAttribute(of: element, kAXPositionAttribute) }

    var size: CGSize? { Self.sizeAttribute(of: element, kAXSizeAttribute) }

    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    var isResizable: Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &isSettable) == .success
            && isSettable.boolValue
    }

    func set(position: CGPoint) -> AXError {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func set(size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    func restoreEnhancedUIIfNeeded() {
        guard enhancedUIWasEnabled else { return }
        AXUIElementSetAttributeValue(appElement, Self.enhancedUserInterfaceAttribute, kCFBooleanTrue)
    }

    static func position(of element: AXUIElement) -> CGPoint? {
        pointAttribute(of: element, kAXPositionAttribute)
    }

    static func size(of element: AXUIElement) -> CGSize? {
        sizeAttribute(of: element, kAXSizeAttribute)
    }

    private static func pointAttribute(of element: AXUIElement, _ name: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(of element: AXUIElement, _ name: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func stringAttribute(of element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func boolAttribute(of element: AXUIElement, _ name: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }
}
