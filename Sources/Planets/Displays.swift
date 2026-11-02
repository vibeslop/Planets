import AppKit
import PlanetsCore

/// Converts between AppKit's screen model and PlanetsCore's.
///
/// AppKit puts the origin at the bottom-left of the primary display with y growing up;
/// the Accessibility API and PlanetsCore put it at the top-left with y growing down.
/// Everything crosses between the two here and nowhere else.
@MainActor
enum Displays {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toGlobal(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAppKit(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAppKit(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func toGlobal(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func id(of screen: NSScreen) -> MonitorID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func monitors() -> [Monitor] {
        NSScreen.screens.enumerated().map { index, screen in
            Monitor(
                id: id(of: screen),
                name: screen.localizedName,
                frame: toGlobal(screen.frame),
                visibleFrame: toGlobal(screen.visibleFrame),
                isMain: index == 0
            )
        }
    }

    static func screen(for id: MonitorID?) -> NSScreen? {
        NSScreen.screens.first { Self.id(of: $0) == id }
    }

}
