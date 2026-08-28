import SwiftUI

/// Kuulla "Signal" design tokens.
///
/// Colours mirror `docs/brand.md` §10 and are backed by an asset catalog
/// (`Assets.xcassets/Colors/*.colorset`, Any = light / Dark appearances) so they
/// follow the system appearance automatically. This enum is the type-safe
/// accessor; `Radius` and `Space` carry the scales from §5–§6.
enum KuullaColor {
    static let background = Color("Background")
    static let surface = Color("Surface")
    static let surfaceRaised = Color("SurfaceRaised")
    static let surfacePressed = Color("SurfacePressed")
    static let line = Color("Line")
    static let textPrimary = Color("TextPrimary")
    static let textMuted = Color("TextMuted")
    static let textFaint = Color("TextFaint")

    /// The lime accent — a true signal. Fills only: primary action, playing
    /// state, sync-fresh, focus. Never body text (see `signalInk`).
    static let signal = Color("Signal")
    /// Lime used *as text* — lime on dark, darkened olive-lime on light so it
    /// stays AA-legible on both grounds.
    static let signalInk = Color("SignalInk")
    /// Tinted lime background — active rows, highlights, focus rings.
    static let signalSoft = Color("SignalSoft")
    /// Text/icons drawn on top of a `signal` fill.
    static let onSignal = Color("OnSignal")

    static let success = Color("Success")
    static let danger = Color("Danger")
    static let info = Color("Info")
    static let warning = Color("Warning")
}

/// Corner radii in points — `docs/brand.md` §6.
enum Radius {
    /// Inputs, badges, chips, segmented controls.
    static let sm: CGFloat = 4
    /// Cards, list rows, inline panels.
    static let md: CGFloat = 6
    /// Standalone buttons, modals, sheets, hero panels.
    static let lg: CGFloat = 10
}

/// Spacing scale in points, 4pt base — `docs/brand.md` §5.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}
