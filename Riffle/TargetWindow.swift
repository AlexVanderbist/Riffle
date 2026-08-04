import ApplicationServices

/// Cached Accessibility boundary for the Target Window and its owning app.
nonisolated final class TargetWindow: @unchecked Sendable {
    let element: AXUIElement

    private let appElement: AXUIElement
    private let enhancedUIWasEnabled: Bool
    private static let axMessagingTimeout: Float = 0.25
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    static func element(at location: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y), &element) == .success,
              let element else { return nil }

        if stringAttribute(of: element, kAXRoleAttribute) == kAXWindowRole { return element }

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        return (windowRef as! AXUIElement)
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
