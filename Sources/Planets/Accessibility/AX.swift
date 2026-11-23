import ApplicationServices
import CoreGraphics
import PlanetsCore
import PlanetsPrivate

extension AXUIElement {
    func attribute<T>(_ name: String, as _: T.Type = T.self) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func string(_ name: String) -> String? { attribute(name, as: String.self) }
    func bool(_ name: String) -> Bool? { attribute(name, as: Bool.self) }

    func element(_ name: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement] {
        elementsIfAvailable(name) ?? []
    }

    func elementsIfAvailable(_ name: String) -> [AXUIElement]? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(self, name as CFString, &value)
        if error == .noValue { return [] }
        guard error == .success, let array = value as? [AnyObject] else { return nil }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    var position: CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, kAXPositionAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(self, kAXSizeAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value)
    }

    @discardableResult
    func set(_ name: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    func isSettable(_ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success && settable.boolValue
    }

    var windowID: WindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(self, action as CFString)
    }
}

struct WindowSnapshot: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case tile
        case float
        case ignore
        case unknown
    }

    var id: WindowID
    var title: String
    var frame: CGRect
    var kind: Kind
    var subrole: String
    var isFullScreen = false
    var isMinimized = false
}

enum WindowClassifier {
    static func classify(_ window: AXUIElement) -> (kind: WindowSnapshot.Kind, subrole: String, fullScreen: Bool, minimized: Bool) {
        guard let role = window.string(kAXRoleAttribute) else { return (.unknown, "", false, false) }
        guard role == kAXWindowRole else { return (.ignore, "", false, false) }
        let subrole = window.string(kAXSubroleAttribute) ?? ""
        if window.bool(kAXMinimizedAttribute) == true { return (.ignore, subrole, false, true) }
        if window.bool("AXFullScreen") == true { return (.ignore, subrole, true, false) }
        return (kind(window, subrole: subrole), subrole, false, false)
    }

    private static func kind(_ window: AXUIElement, subrole: String) -> WindowSnapshot.Kind {
        switch subrole {
        case kAXStandardWindowSubrole:
            break
        case kAXDialogSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole:
            return .float
        default:
            return .ignore
        }
        if let size = window.size, size.width < 60 || size.height < 60 { return .ignore }
        guard window.isSettable(kAXSizeAttribute) else { return .float }
        let zoom = window.element(kAXZoomButtonAttribute)
        let fullScreen = window.element(kAXFullScreenButtonAttribute)
        if zoom == nil && fullScreen == nil { return .float }
        if let zoom, zoom.bool(kAXEnabledAttribute) == false, fullScreen == nil { return .float }
        return .tile
    }
}
