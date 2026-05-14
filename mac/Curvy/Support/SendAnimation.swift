import SwiftUI

/// Single source of truth for the send-bubble animation timings.
/// Three motions need to feel like one:
///   - `pushUp`   — the cachedRows mutation that shifts older rows
///                  upward when a new tail row is inserted.
///   - `scroll`   — the viewport snap-to-bottom that puts the new
///                  bubble in view. Same curve as `pushUp` so the
///                  motions read as one transaction.
///   - `entrance` — the new bubble's scale+opacity rise, played
///                  after `entranceDelay` so it lands once the
///                  viewport has finished moving.
///
/// `entranceMaxAge` is the staleness gate for an outgoing row to
/// trigger the entrance animation on first appear. Cold-loaded
/// history (rows older than this) skips the animation entirely.
enum SendAnimation {
    static let pushUp: Animation = .spring(response: 0.28, dampingFraction: 0.86)
    static let scroll: Animation = .spring(response: 0.28, dampingFraction: 0.86)
    static let entrance: Animation = .spring(response: 0.34, dampingFraction: 0.72)
    static let entranceDelay: Double = 0.2
    static let entranceMaxAge: TimeInterval = 2.0
}
