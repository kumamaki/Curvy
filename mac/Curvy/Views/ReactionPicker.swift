import SwiftUI

/// iMessage-style tapback bar — a glass capsule of 6 fixed emojis that
/// floats above (or beside) a message bubble when the user clicks the
/// hover smiley or picks "React" from the context menu.
///
/// The presets are deliberately fixed at 6 (heart, thumbs up/down,
/// laugh, exclamation, question) to match Apple's tapback affordance.
/// A separate "more emojis" surface is out of scope for v2 — if a
/// friend needs a different emoji we add it to `presets`.
///
/// Each emoji button is the **source** of a `matchedGeometryEffect`
/// pair. When tapped, the optimistic `CachedMessage` row inserted by
/// `MessageStore.sendReaction` causes a `ReactionBadgeStack` capsule
/// to appear on the bubble corner with the same matching id, and
/// SwiftUI animates the emoji "stick" — the same motion iMessage does
/// when a tapback lands. The shared namespace lives on `ChatView`.
struct ReactionPicker: View {
    let targetID: String
    let mineByEmoji: Set<String>
    let namespace: Namespace.ID
    let onPick: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One bit per preset emoji: `true` once the corresponding button
    /// has been revealed by the stagger sequence in `.task`. Drives the
    /// scale + opacity transition so the bar visibly *unfurls* rather
    /// than appearing in one frame.
    @State private var revealed: [Bool] = Array(repeating: false, count: ReactionPicker.presets.count)

    static let presets: [String] = [
        "😆", "💃🏻", "♥️", "🎉", "⭐", "🤣",
        "😍", "🫨", "🙂\u{200D}↔️", "🙂\u{200D}↕️", "🫩", "😵\u{200D}💫",
        "💀", "👍🏻", "🤌🏻", "👀", "🍑", "🍆"
    ]

    /// 6 columns × 3 rows = 18. A flat horizontal bar would be ~720pt
    /// wide and overflow most chat windows; a grid keeps the picker
    /// compact while still scanning faster than a vertical list.
    private static let columnCount = 6

    private static let columns: [GridItem] = Array(
        repeating: GridItem(.fixed(36), spacing: 4),
        count: ReactionPicker.columnCount
    )

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 4) {
            ForEach(Array(Self.presets.enumerated()), id: \.element) { index, emoji in
                PickerEmojiButton(
                    emoji: emoji,
                    isMine: mineByEmoji.contains(emoji),
                    namespace: namespace,
                    targetID: targetID,
                    action: { onPick(emoji) }
                )
                .opacity(revealed[index] ? 1 : 0)
                .scaleEffect(revealed[index] ? 1 : 0.4, anchor: .bottom)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .task { await stagger() }
    }

    /// Reveal each emoji button ~12ms after the previous one. With
    /// 18 buttons the per-step delay has to drop from the original
    /// 25ms — at 25ms total reveal is ~450ms, which feels sluggish
    /// for a tapback. 12ms × 18 = ~215ms total: fast enough to feel
    /// instant, slow enough that the eye still catches the cascade.
    ///
    /// Running directly inside the `.task` closure (not in a detached
    /// inner Task) means SwiftUI's automatic cancellation on re-appear
    /// actually reaches the `Task.sleep` calls and stops the old
    /// stagger before the new one begins.
    @MainActor
    private func stagger() async {
        revealed = Array(repeating: false, count: Self.presets.count)
        let perStep = reduceMotion ? Duration.zero : .milliseconds(12)
        for index in revealed.indices {
            withAnimation(reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.78)) {
                revealed[index] = true
            }
            try? await Task.sleep(for: perStep)
        }
    }
}

/// One emoji in the tapback row. Hover bounces it up + scales it; tap
/// fires the picker's `onPick`. The `matchedGeometryEffect` source ID
/// is keyed by `(targetID, emoji)` so the destination capsule on the
/// bubble can match into the *same* emoji even when several pickers
/// are open at once on different bubbles (defensive — only one is
/// ever visible at a time in practice).
private struct PickerEmojiButton: View {
    let emoji: String
    let isMine: Bool
    let namespace: Namespace.ID
    let targetID: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
                .background {
                    // Soft tint disc shows up only when this emoji is
                    // already the user's reaction — visually says "tap
                    // to remove". The whole bar's glass capsule is the
                    // shared backdrop; individual buttons stay flat.
                    if isMine {
                        Circle().fill(.tint.opacity(0.25))
                    }
                }
                .scaleEffect(isHovering ? 1.25 : 1.0)
                .offset(y: isHovering ? -2 : 0)
                .matchedGeometryEffect(
                    id: "reaction-\(targetID)-\(emoji)",
                    in: namespace,
                    properties: .position,
                    anchor: .center,
                    isSource: true
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.28, dampingFraction: 0.6),
            value: isHovering
        )
        .help(isMine ? "Remove \(emoji)" : "React with \(emoji)")
        .accessibilityLabel(isMine ? "Remove \(emoji) reaction" : "React with \(emoji)")
    }
}

