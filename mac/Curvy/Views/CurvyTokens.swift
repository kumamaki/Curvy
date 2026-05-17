import SwiftUI

/// Shared corner radii. Only values that repeat across multiple call
/// sites live here — one-off radii (the 14pt invite paste box, the
/// 22pt reaction picker capsule, the 1.5pt reply stripe) stay as
/// inline literals so this file doesn't pretend to be a complete
/// design system when it isn't.
enum CurvyRadius {
    /// Composer text input and the drop-zone overlay — surfaces that
    /// read as "type/drop here." Anything that visually echoes the
    /// input field should reuse this.
    static let input: CGFloat = 18

    /// Inline chips that ride inside the composer card (image preview,
    /// reply banner). Smaller than `input` so the chip reads as a
    /// child of the composer surface, not a sibling.
    static let chip: CGFloat = 10

    /// Floating menus / pickers (mention picker container).
    static let card: CGFloat = 12

    /// Message bubble corners. `bubble` is the standard radius;
    /// `bubbleTail` is the tiny corner on the side closest to the
    /// sender's edge, used only on the last bubble in a group.
    static let bubble: CGFloat = 16
    static let bubbleTail: CGFloat = 4
}
