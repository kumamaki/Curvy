import Foundation

/// Polymorphic plaintext for a single message inside a sealed envelope.
/// The `type` discriminator on the wire selects the case; v1 added
/// `.text`, v3 adds `.image`. The enum is shaped so v2 reactions and
/// v4 generic files plug in by adding a new case here and a matching
/// value in `Kind`. Existing clients reject unknown discriminators
/// rather than silently dropping content — fail loud, not soft.
enum MessagePayload: Codable, Sendable, Equatable {
    case text(TextMessage)
    case image(ImageMessage)
    case reaction(ReactionMessage)
    case reactionRemove(ReactionRemoveMessage)

    enum Kind: String, Codable, Sendable {
        case text
        case image
        case reaction
        case reactionRemove = "reaction_remove"
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .text:
            self = .text(try TextMessage(from: decoder))
        case .image:
            self = .image(try ImageMessage(from: decoder))
        case .reaction:
            self = .reaction(try ReactionMessage(from: decoder))
        case .reactionRemove:
            self = .reactionRemove(try ReactionRemoveMessage(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let message):
            try container.encode(Kind.text, forKey: .type)
            try message.encode(to: encoder)
        case .image(let message):
            try container.encode(Kind.image, forKey: .type)
            try message.encode(to: encoder)
        case .reaction(let message):
            try container.encode(Kind.reaction, forKey: .type)
            try message.encode(to: encoder)
        case .reactionRemove(let message):
            try container.encode(Kind.reactionRemove, forKey: .type)
            try message.encode(to: encoder)
        }
    }
}

/// A plain text message inside an encrypted envelope.
///
/// `sender` is the local display name set by each client — it lives
/// inside the ciphertext on purpose, so GitHub never sees who sent
/// what. Empty strings are valid (anonymous-by-default) but the field
/// is required structurally so we never forget to wire it.
///
/// `replyTo`, when non-nil, is the GitHub comment ID of the target
/// message. We use the comment ID directly rather than a synthetic
/// UUID so old messages are addressable without a separate ID layer
/// — and because the comment ID is the only identifier guaranteed to
/// already exist on every client.
struct TextMessage: Codable, Sendable, Equatable {
    let sender: String
    let body: String
    let replyTo: String?
    let sentAt: Date

    enum CodingKeys: String, CodingKey {
        case sender
        case body
        case replyTo = "reply_to"
        case sentAt = "sent_at"
    }

    init(sender: String, body: String, replyTo: String?, sentAt: Date) {
        self.sender = sender
        self.body = body
        self.replyTo = replyTo
        // sentAt rides the wire as an Int64 millisecond count since
        // 1970 (see encode/decode). We picked Int64-ms over ISO-8601
        // string after slice 1 hit floating-point ε round-trip drift:
        // the inner JSON is always inside ciphertext so nobody ever
        // grep-reads it, and a deterministic round-trip is worth more
        // than human readability we never use. Normalising through the
        // same Int64-ms conversion at construction guarantees every
        // TextMessage's sentAt is the canonical wire-stable Double.
        self.sentAt = canonicalDate(from: sentAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sender = try container.decode(String.self, forKey: .sender)
        let body = try container.decode(String.self, forKey: .body)
        let replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        let ms = try container.decode(Int64.self, forKey: .sentAt)
        self.init(
            sender: sender,
            body: body,
            replyTo: replyTo,
            sentAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sender, forKey: .sender)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        let ms = Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
        try container.encode(ms, forKey: .sentAt)
    }
}

/// An image message inside an encrypted envelope.
///
/// The image bytes themselves are NOT in this struct — they live as a
/// committed file on `curvy-room`'s `blobs` branch at `assetPath`,
/// encrypted under a fresh per-file AES-GCM key (`keyB64`/`nonceB64`).
/// The per-file key is wrapped here, inside the room-key envelope, so
/// the room key never touches the blob host: a leaked file URL without
/// the envelope reveals only opaque ciphertext.
///
/// Why path + sha and not the original spec's `asset_id` numeric:
/// originally we planned to use GitHub Releases assets (numeric IDs),
/// but `uploads.github.com` and `release-assets.githubusercontent.com`
/// are blocked from at least one of our networks. We pivoted to the
/// Contents API, which addresses files by path + git SHA. Path is
/// stable and predictable (`blobs/<uuid>.bin`); SHA is what the Git
/// Blobs API GET takes and what the Contents API DELETE requires in
/// the request body.
///
/// The optional fields (`width`, `height`, `caption`, `replyTo`) are
/// extensions over the original `CLAUDE.md` sketch — old text-only
/// clients reject the whole `.image` discriminator anyway, so adding
/// optionals here doesn't break anything that wasn't already going to
/// hit the `.weird` path.
struct ImageMessage: Codable, Sendable, Equatable {
    let sender: String
    let assetPath: String
    let assetSha: String
    let mime: String
    let keyB64: String
    let nonceB64: String
    let size: Int
    let width: Int?
    let height: Int?
    let caption: String?
    let replyTo: String?
    let sentAt: Date

    enum CodingKeys: String, CodingKey {
        case sender
        case assetPath = "asset_path"
        case assetSha = "asset_sha"
        case mime
        case keyB64 = "key"
        case nonceB64 = "nonce"
        case size
        case width
        case height
        case caption
        case replyTo = "reply_to"
        case sentAt = "sent_at"
    }

    init(sender: String,
         assetPath: String,
         assetSha: String,
         mime: String,
         keyB64: String,
         nonceB64: String,
         size: Int,
         width: Int?,
         height: Int?,
         caption: String?,
         replyTo: String?,
         sentAt: Date) {
        self.sender = sender
        self.assetPath = assetPath
        self.assetSha = assetSha
        self.mime = mime
        self.keyB64 = keyB64
        self.nonceB64 = nonceB64
        self.size = size
        self.width = width
        self.height = height
        self.caption = caption
        self.replyTo = replyTo
        self.sentAt = canonicalDate(from: sentAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sender = try container.decode(String.self, forKey: .sender)
        let assetPath = try container.decode(String.self, forKey: .assetPath)
        let assetSha = try container.decode(String.self, forKey: .assetSha)
        let mime = try container.decode(String.self, forKey: .mime)
        let keyB64 = try container.decode(String.self, forKey: .keyB64)
        let nonceB64 = try container.decode(String.self, forKey: .nonceB64)
        let size = try container.decode(Int.self, forKey: .size)
        let width = try container.decodeIfPresent(Int.self, forKey: .width)
        let height = try container.decodeIfPresent(Int.self, forKey: .height)
        let caption = try container.decodeIfPresent(String.self, forKey: .caption)
        let replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        let ms = try container.decode(Int64.self, forKey: .sentAt)
        self.init(
            sender: sender,
            assetPath: assetPath,
            assetSha: assetSha,
            mime: mime,
            keyB64: keyB64,
            nonceB64: nonceB64,
            size: size,
            width: width,
            height: height,
            caption: caption,
            replyTo: replyTo,
            sentAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sender, forKey: .sender)
        try container.encode(assetPath, forKey: .assetPath)
        try container.encode(assetSha, forKey: .assetSha)
        try container.encode(mime, forKey: .mime)
        try container.encode(keyB64, forKey: .keyB64)
        try container.encode(nonceB64, forKey: .nonceB64)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(caption, forKey: .caption)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        let ms = Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
        try container.encode(ms, forKey: .sentAt)
    }
}

/// A reaction (an emoji applied by `sender` to a target message).
///
/// `targetID` is the GitHub comment ID of the message being reacted
/// to, stringified — same addressing as `TextMessage.replyTo`. Using
/// the comment ID directly means reactions don't need a synthetic ID
/// layer and stay addressable across re-polling.
///
/// `sender` lives inside the ciphertext per the project's hard rule
/// that identity must never be derivable from `comment.user.login`.
/// CLAUDE.md's wire-format sketch omitted `sender`, but it's required
/// for grouping ("who already reacted with X?") and for the toggle
/// resolver — adding it follows the spirit of the identity-inside-
/// ciphertext rule, which is load-bearing.
struct ReactionMessage: Codable, Sendable, Equatable {
    let sender: String
    let targetID: String
    let emoji: String
    let sentAt: Date

    enum CodingKeys: String, CodingKey {
        case sender
        case targetID = "target_id"
        case emoji
        case sentAt = "sent_at"
    }

    init(sender: String, targetID: String, emoji: String, sentAt: Date) {
        self.sender = sender
        self.targetID = targetID
        self.emoji = emoji
        self.sentAt = canonicalDate(from: sentAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sender = try container.decode(String.self, forKey: .sender)
        let targetID = try container.decode(String.self, forKey: .targetID)
        let emoji = try container.decode(String.self, forKey: .emoji)
        let ms = try container.decode(Int64.self, forKey: .sentAt)
        self.init(
            sender: sender,
            targetID: targetID,
            emoji: emoji,
            sentAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sender, forKey: .sender)
        try container.encode(targetID, forKey: .targetID)
        try container.encode(emoji, forKey: .emoji)
        let ms = Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
        try container.encode(ms, forKey: .sentAt)
    }
}

/// Revokes a previously-sent reaction. Carries `sentAt` so a remove
/// can win against a same-tick re-add of the same emoji from the
/// same sender — the render-time aggregator picks the winner by
/// timestamp. Without `sentAt`, re-polling could permanently lose
/// the ordering information needed to resolve toggles.
struct ReactionRemoveMessage: Codable, Sendable, Equatable {
    let sender: String
    let targetID: String
    let emoji: String
    let sentAt: Date

    enum CodingKeys: String, CodingKey {
        case sender
        case targetID = "target_id"
        case emoji
        case sentAt = "sent_at"
    }

    init(sender: String, targetID: String, emoji: String, sentAt: Date) {
        self.sender = sender
        self.targetID = targetID
        self.emoji = emoji
        self.sentAt = canonicalDate(from: sentAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sender = try container.decode(String.self, forKey: .sender)
        let targetID = try container.decode(String.self, forKey: .targetID)
        let emoji = try container.decode(String.self, forKey: .emoji)
        let ms = try container.decode(Int64.self, forKey: .sentAt)
        self.init(
            sender: sender,
            targetID: targetID,
            emoji: emoji,
            sentAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sender, forKey: .sender)
        try container.encode(targetID, forKey: .targetID)
        try container.encode(emoji, forKey: .emoji)
        let ms = Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
        try container.encode(ms, forKey: .sentAt)
    }
}

/// Round-trips a Date through the same Int64-ms conversion used on the
/// wire so `==` comparisons after a seal/open cycle are reliable.
/// Pulled out of `TextMessage` so `ImageMessage` can share it without
/// either type owning it.
private func canonicalDate(from date: Date) -> Date {
    let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
    return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
}

