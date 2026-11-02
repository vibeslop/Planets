import AppKit
import PlanetsCore

/// Colour lives in two places only: the app icon and the light around the focused window.
/// Everything else, from the menu to the menu bar strip, uses the system's own colours and
/// the user's accent, so the app looks like part of the Mac rather than painted over it.
enum Theme {
    // Display P3.
    static let gold = NSColor(displayP3Red: 1.0, green: 0.80, blue: 0.20, alpha: 1)
    /// The bright core of the light.
    static let goldLight = NSColor(displayP3Red: 1.0, green: 0.92, blue: 0.62, alpha: 1)
    static let amber = NSColor(displayP3Red: 0.98, green: 0.58, blue: 0.14, alpha: 1)
    static let pearl = NSColor(displayP3Red: 0.99, green: 0.98, blue: 0.96, alpha: 1)

    /// The rim, clockwise from the top-left corner: gold light, brightest at the top.
    static let rimStops: [(color: NSColor, location: CGFloat)] = [
        (goldLight, 0.00), (gold, 0.30), (goldLight, 0.55), (gold, 0.80), (goldLight, 1.00),
    ]

    /// The haze around the rim: one connected cloud of gold warming into amber and back,
    /// densest at the top left, thinning toward the bottom left. A touch stronger than it
    /// would be on open space, since the gap around a window is narrow and usually dark.
    static let bloomStops: [(color: NSColor, location: CGFloat)] = [
        (gold.withAlphaComponent(0.99), 0.00),
        (amber.withAlphaComponent(0.77), 0.18),
        (goldLight.withAlphaComponent(0.55), 0.36),
        (gold.withAlphaComponent(0.83), 0.52),
        (amber.withAlphaComponent(0.39), 0.68),
        (gold.withAlphaComponent(0.13), 0.82),
        (gold.withAlphaComponent(0.99), 1.00),
    ]

    /// The rim and haze stops for the focused window in each colour the user can pick.
    /// Every palette keeps gold's shape: a bright core that brightens at the top, and a
    /// haze densest at the top left that thins toward the bottom left.
    /// `dark` is whether the Mac is in dark mode, which only the neutral colour depends on.
    static func palette(_ color: GlowColor, dark: Bool = true) -> (rim: [(color: NSColor, location: CGFloat)], bloom: [(color: NSColor, location: CGFloat)]) {
        func shaped(core: NSColor, light: NSColor, deep: NSColor) -> (rim: [(color: NSColor, location: CGFloat)], bloom: [(color: NSColor, location: CGFloat)]) {
            let rim: [(color: NSColor, location: CGFloat)] = [(light, 0), (core, 0.30), (light, 0.55), (core, 0.80), (light, 1)]
            let bloom: [(color: NSColor, location: CGFloat)] = [
                (core.withAlphaComponent(0.9), 0.00), (deep.withAlphaComponent(0.7), 0.18), (light.withAlphaComponent(0.5), 0.36),
                (core.withAlphaComponent(0.75), 0.52), (deep.withAlphaComponent(0.35), 0.68), (core.withAlphaComponent(0.12), 0.82),
                (core.withAlphaComponent(0.9), 1.00),
            ]
            return (rim, bloom)
        }
        switch color {
        case .gold:
            return (rimStops, bloomStops)
        case .accent:
            let accent = NSColor.controlAccentColor.usingColorSpace(.displayP3) ?? .systemBlue
            return shaped(core: accent, light: accent.blended(withFraction: 0.45, of: .white) ?? accent, deep: accent.blended(withFraction: 0.2, of: .black) ?? accent)
        case .neutral where dark:
            return shaped(core: NSColor(white: 0.9, alpha: 1), light: pearl, deep: NSColor(displayP3Red: 0.86, green: 0.88, blue: 0.92, alpha: 1))
        case .neutral:
            return shaped(core: NSColor(white: 0.42, alpha: 1), light: NSColor(white: 0.58, alpha: 1), deep: NSColor(white: 0.3, alpha: 1))
        }
    }
}
