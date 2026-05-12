import Foundation
import Testing
@testable import Curvy

/// `emojiOnlyCount` is the gate for the jumbo emoji presentation in
/// `MessageRow`. The classification is Unicode-property-driven rather
/// than scalar-table-driven, so these tests pin down the boundaries
/// that actually matter to chat: plain emoji, ZWJ joins,
/// regional-indicator flag pairs, skin-tone modifier sequences,
/// VS-16 text→emoji upgrades, and the negative cases (ASCII digits,
/// mixed text, empty). If a future Unicode update reshuffles
/// `isEmoji` / `isEmojiPresentation`, this is where the regression
/// would land.
struct EmojiDetectTests {
    @Test("empty body is not emoji-only")
    func emptyBody() {
        #expect("".emojiOnlyCount == nil)
    }

    @Test("whitespace-only body is not emoji-only")
    func whitespaceOnly() {
        #expect("   ".emojiOnlyCount == nil)
    }

    @Test("plain ASCII returns nil")
    func plainText() {
        #expect("hi".emojiOnlyCount == nil)
    }

    @Test("single emoji counts as 1")
    func singleEmoji() {
        #expect("👍".emojiOnlyCount == 1)
    }

    @Test("skin-tone modifier sequence stays one cluster")
    func skinToneModifier() {
        #expect("👍🏽".emojiOnlyCount == 1)
    }

    @Test("regional-indicator flag pair is one cluster")
    func flagEmoji() {
        #expect("🇯🇵".emojiOnlyCount == 1)
    }

    @Test("ZWJ family sequence is one cluster")
    func zwjFamily() {
        #expect("👨‍👩‍👧".emojiOnlyCount == 1)
    }

    @Test("three back-to-back emoji")
    func threeEmoji() {
        #expect("😀😀😀".emojiOnlyCount == 3)
    }

    @Test("four emoji counts past jumbo threshold")
    func fourEmoji() {
        // We don't render 4+ as jumbo, but the count must still be
        // reported so the caller knows it's emoji-only.
        #expect("😀😀😀😀".emojiOnlyCount == 4)
    }

    @Test("inter-emoji whitespace is tolerated")
    func whitespacePadding() {
        #expect("  😀  😂 ".emojiOnlyCount == 2)
    }

    @Test("mixed text + emoji disqualifies the body")
    func mixedEmojiAndText() {
        #expect("😀 hi".emojiOnlyCount == nil)
    }

    @Test("ASCII digits are not emoji")
    func digits() {
        // 0-9 carry the Emoji property but default to text
        // presentation. Without the multi-scalar guard in
        // `Character.isEmoji`, this case would false-positive.
        #expect("123".emojiOnlyCount == nil)
    }

    @Test("VS-16 heart counts as emoji")
    func heartVS16() {
        // U+2764 + U+FE0F — the variation selector promotes the
        // text-default heart to emoji presentation.
        #expect("❤️".emojiOnlyCount == 1)
    }
}

