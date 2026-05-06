import SwiftUI

/// One distinct emoji's worth of live reactions on a target message.
/// `senders` is the de-duplicated list of display names that have an
/// active reaction with this emoji (ordered by sentAt ascending);
/// `earliestSentAt` is the timestamp of the first reaction in the
/// group and drives stable left-to-right ordering of badges.
struct ReactionGroup: Identifiable, Hashable {
    let emoji: String
    let senders: [String]
    let earliestSentAt: Date

    var id: String { emoji }
    var count: Int { senders.count }
}

/// Aggregated reaction state for a single target message — the result
/// of folding the raw `.reaction` / `.reactionRemove` `CachedMessage`
/// rows in `ChatView.rows`. Empty when no live reactions exist.
struct MessageReactions: Equatable {
    let targetID: String
    let groups: [ReactionGroup]

    static func empty(targetID: String) -> Self {
        Self(targetID: targetID, groups: [])
    }
}

/// Row of reaction capsules that lives INSIDE the message bubble at
/// its bottom (Telegram-style). Each capsule displays its emoji and
/// a count (hidden when 1). Capsules are tappable — clicking your
/// own toggles it off, clicking someone else's joins the reaction
/// with the same emoji.
///
/// The `matchedGeometryEffect` destination IDs match `ReactionPicker`'s
/// sources, which gives the "stick" animation when an emoji is picked
/// — the system animates the picker emoji into its final badge
/// position rather than fading-in cold.
struct ReactionBadgeStack: View {
    let reactions: MessageReactions
    let mySender: String
    let namespace: Namespace.ID
    let isMine: Bool
    let onToggle: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions.groups) { group in
                ReactionBadge(
                    group: group,
                    isMineActive: group.senders.contains(mySender),
                    namespace: namespace,
                    targetID: reactions.targetID,
                    onTap: { onToggle(group.emoji) }
                )
                .transition(badgeTransition)
            }
        }
        .animation(
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.82),
            value: reactions.groups
        )
    }

    /// Arrival: scale-up from 0 with a slight overshoot via spring,
    /// plus opacity. Departure: scale-down to 0.6 + opacity. The
    /// overshoot is what gives reactions their tactile "land + settle"
    /// feel — pure linear scale would feel mechanical.
    private var badgeTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0, anchor: .center).combined(with: .opacity),
            removal: .scale(scale: 0.6, anchor: .center).combined(with: .opacity)
        )
    }
}

/// One emoji+count chip. Pulled out so the matchedGeometry id can sit
/// on a stable view per emoji and so wobble-on-arrival can run as a
/// per-instance `.task`.
private struct ReactionBadge: View {
    let group: ReactionGroup
    let isMineActive: Bool
    let namespace: Namespace.ID
    let targetID: String
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wobble: Double = -4
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Text(group.emoji)
                    .font(.system(size: 13))
                    .matchedGeometryEffect(
                        id: "reaction-\(targetID)-\(group.emoji)",
                        in: namespace,
                        properties: .position,
                        anchor: .center,
                        isSource: false
                    )
                if group.count > 1 {
                    Text("\(group.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .contentTransition(.numericText(value: Double(group.count)))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                // Translucent white over the bubble's color. Tuned by
                // whether the user has reacted with this emoji:
                // active = brighter (0.30 opacity) so it reads as
                // highlighted, inactive = subtler (0.18 opacity) so it
                // sits as quiet metadata. Both values picked to be
                // legible on either the brand-orange bubble (mine) or
                // the dark `curvyInk` bubble (theirs) without per-side
                // tuning — translucent white over color always reads
                // as a frosted highlight.
                Capsule().fill(Color.white.opacity(isMineActive ? 0.30 : 0.18))
            }
            .rotationEffect(.degrees(wobble))
            .scaleEffect(isHovering ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(
            reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.12),
            value: isHovering
        )
        .help(isMineActive ? "Remove your \(group.emoji)" : "React with \(group.emoji)")
        .accessibilityLabel(label(for: group))
        .task {
            // Subtle settle: -4° → 0°. Inside-the-bubble badges don't
            // need the bigger -8° "land" feel — they're not arriving
            // from above the bubble like an iMessage tapback, they're
            // appearing in-place inside their host. A small rotation
            // is enough to suggest motion without screaming.
            withAnimation(reduceMotion ? .linear(duration: 0) : .spring(response: 0.45, dampingFraction: 0.6)) {
                wobble = 0
            }
        }
    }

    private func label(for group: ReactionGroup) -> String {
        let participants = group.senders.joined(separator: ", ")
        return "\(group.emoji) reacted by \(participants)"
    }
}

