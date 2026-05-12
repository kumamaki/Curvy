import Foundation

/// "Is this message body just an emoji?" — the single question this
/// file exists to answer. Drives the jumbo presentation in
/// `MessageRow`: 1 emoji renders at 56pt, 2 at 44pt, 3 at 32pt, 4+
/// falls back to the normal 13pt bubble.
///
/// Telegram, iMessage, WhatsApp, and Signal all do this; the only
/// novel detail is where to draw the "emoji" boundary, which
/// `Character.isEmoji` below handles via Unicode properties rather
/// than a hard-coded scalar table.

extension Character {
    /// True for grapheme clusters that present as emoji — covers
    /// plain emoji, ZWJ sequences (e.g. family), regional-indicator
    /// flag pairs, skin-tone modifier sequences, and VS-16
    /// variation-selected text→emoji upgrades. Excludes ASCII digits
    /// and `#`/`*` which technically carry the Emoji property but
    /// default to text presentation.
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        // Default-presentation emoji: rendered as emoji even without
        // a variation selector.
        if first.properties.isEmojiPresentation { return true }
        // Emoji-property scalars that need an explicit "this is
        // emoji" cue — VS-16 follower, skin modifier, ZWJ chain, or
        // regional-indicator partner. All of those produce a cluster
        // with more than one scalar.
        return first.properties.isEmoji && unicodeScalars.count > 1
    }
}

extension String {
    /// `nil` when the trimmed body isn't a pure emoji run, otherwise
    /// the count of emoji grapheme clusters. Inter-emoji whitespace
    /// is tolerated; any non-emoji non-whitespace character
    /// disqualifies the body.
    var emojiOnlyCount: Int? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var count = 0
        for ch in trimmed {
            if ch.isWhitespace { continue }
            guard ch.isEmoji else { return nil }
            count += 1
        }
        return count > 0 ? count : nil
    }
}

