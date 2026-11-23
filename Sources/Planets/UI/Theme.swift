import AppKit
import PlanetsCore

enum Theme {
    static let gold = NSColor(displayP3Red: 1.0, green: 0.80, blue: 0.20, alpha: 1)
    static let goldLight = NSColor(displayP3Red: 1.0, green: 0.92, blue: 0.62, alpha: 1)
    static let amber = NSColor(displayP3Red: 0.98, green: 0.58, blue: 0.14, alpha: 1)
    static let pearl = NSColor(displayP3Red: 0.99, green: 0.98, blue: 0.96, alpha: 1)

    static let rimStops: [(color: NSColor, location: CGFloat)] = [
        (goldLight, 0.00), (gold, 0.30), (goldLight, 0.55), (gold, 0.80), (goldLight, 1.00),
    ]

    static let bloomStops: [(color: NSColor, location: CGFloat)] = [
        (gold.withAlphaComponent(0.99), 0.00),
        (amber.withAlphaComponent(0.77), 0.18),
        (goldLight.withAlphaComponent(0.55), 0.36),
        (gold.withAlphaComponent(0.83), 0.52),
        (amber.withAlphaComponent(0.39), 0.68),
        (gold.withAlphaComponent(0.13), 0.82),
        (gold.withAlphaComponent(0.99), 1.00),
    ]

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
