import SwiftUI

extension Color {
    /// Primary brand accent — `#2E99FF` sky-blue.
    static let curvyBrand = Color(.sRGB, red: 46.0 / 255.0, green: 153.0 / 255.0, blue: 255.0 / 255.0, opacity: 1.0)

    /// Soft peach accent — the trailing colour of the icon's gradient.
    /// Used for secondary brand surfaces (subtle highlights, hover
    /// states) where the primary orange would be too saturated.
    static let curvyBrandSoft = Color(.displayP3, red: 0.968, green: 0.622, blue: 0.562)

    /// Near-black for solid UI surfaces (incoming message bubbles,
    /// the Unlock button). Pure `#000` is too harsh against the
    /// window's Liquid Glass — it reads as a hole, not a surface.
    /// `curvyInk` is `~#1E1E20` in display-P3, matching the brand
    /// orange's color space and keeping a faint warmth so white text
    /// settles instead of vibrating.
    static let curvyInk = Color(.displayP3, red: 0.118, green: 0.118, blue: 0.125)
}

