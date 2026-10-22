import ApplicationServices

struct WindowAttributes {
    var subrole: String?
    var title: String?
    var isMinimized = false
    var size: CGSize?
}

extension AXUIElement {
    /// Subrole, title, minimized state and size in one round trip to the app instead of four.
    var windowAttributes: WindowAttributes {
        let names = [kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute, kAXSizeAttribute]
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, names as CFArray, AXCopyMultipleAttributeOptions(), &raw) == .success,
              let values = raw as? [AnyObject], values.count == names.count else {
            return WindowAttributes(subrole: subrole, title: title, isMinimized: isMinimized, size: size)
        }
        func axValue(_ value: AnyObject) -> AXValue? {
            CFGetTypeID(value) == AXValueGetTypeID() ? unsafeBitCast(value, to: AXValue.self) : nil
        }
        // Attributes the window doesn't have come back as AXValues wrapping an AXError.
        let usable = values.map { value -> AnyObject? in
            axValue(value).map { AXValueGetType($0) == .axError } == true ? nil : value
        }
        var attributes = WindowAttributes()
        attributes.subrole = usable[0] as? String
        attributes.title = usable[1] as? String
        attributes.isMinimized = usable[2] as? Bool ?? false
        if let sizeValue = usable[3].flatMap(axValue) {
            var size = CGSize.zero
            if AXValueGetValue(sizeValue, .cgSize, &size) { attributes.size = size }
        }
        return attributes
    }

    func value<T>(_ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    /// nil when the app couldn't be asked at all (no permission, hung, still launching); empty when it has no windows.
    var windows: [AXUIElement]? {
        var raw: CFTypeRef?
        switch AXUIElementCopyAttributeValue(self, kAXWindowsAttribute as CFString, &raw) {
        case .success: return raw as? [AXUIElement] ?? []
        case .noValue: return []
        default: return nil
        }
    }

    var focusedWindow: AXUIElement? { value(kAXFocusedWindowAttribute) }
    var subrole: String? { value(kAXSubroleAttribute) }
    var title: String? { value(kAXTitleAttribute) }
    var isMinimized: Bool { value(kAXMinimizedAttribute) ?? false }
    var windowID: CGWindowID? { PrivateAPI.windowID(of: self) }

    var size: CGSize? {
        guard let raw: AXValue = value(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw, .cgSize, &size) ? size : nil
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }
}
