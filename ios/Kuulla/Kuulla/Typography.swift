import SwiftUI

/// The Signal typefaces (`docs/brand.md` §4). The `.ttf` files ship in the app
/// bundle and are registered at launch via `Info.plist`'s `UIAppFonts`.
///
/// All three are variable fonts whose default instance is a light weight, so the
/// `Font.kuulla*` helpers below always pin an explicit `weight:` — calling
/// `Font.custom` without one renders too thin.
enum KuullaFont {
    /// Space Grotesk — headings, the wordmark, large numerals.
    static let display = "Space Grotesk"
    /// Manrope — body copy, list rows, controls.
    static let body = "Manrope"
    /// JetBrains Mono — timestamps, durations, LUFS, ids: anything from the
    /// audio or sync engine.
    static let mono = "JetBrains Mono"
}

extension Font {
    /// Space Grotesk. Headings, the wordmark, large numerals.
    static func kuullaTitle(
        _ size: CGFloat = 22, weight: Font.Weight = .bold,
        relativeTo style: Font.TextStyle = .title2
    ) -> Font {
        .custom(KuullaFont.display, size: size, relativeTo: style).weight(weight)
    }

    /// Manrope. Body copy, list rows, controls.
    static func kuullaBody(
        _ size: CGFloat = 15, weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .body
    ) -> Font {
        .custom(KuullaFont.body, size: size, relativeTo: style).weight(weight)
    }

    /// JetBrains Mono. Timestamps, durations, LUFS, ids — engine numbers.
    static func kuullaMono(
        _ size: CGFloat = 13, weight: Font.Weight = .regular,
        relativeTo style: Font.TextStyle = .caption
    ) -> Font {
        .custom(KuullaFont.mono, size: size, relativeTo: style).weight(weight)
    }
}
