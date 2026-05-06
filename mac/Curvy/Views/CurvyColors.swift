import SwiftUI

extension Color {
    /// Primary brand orange — the leading colour of the app icon's
    /// linear gradient (`icon.json`). Defined in display-P3 to match
    /// the icon exactly on wide-gamut displays; sRGB clamping would
    /// produce a noticeably duller orange against the icon's rendered
    /// version on modern Macs.
    static let curvyBrand = Color(.displayP3, red: 1.0, green: 0.488, blue: 0.147)

    /// Soft peach accent — the trailing colour of the icon's gradient.
    /// Used for secondary brand surfaces (subtle highlights, hover
    /// states) where the primary orange would be too saturated.
    static let curvyBrandSoft = Color(.displayP3, red: 0.968, green: 0.622, blue: 0.562)
}

