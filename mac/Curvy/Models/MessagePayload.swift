import Foundation

/// Polymorphic plaintext for a single message inside a sealed envelope.
/// The `type` discriminator on the wire selects the case; v1 only has
/// `.text` but the enum is shaped so that v2 reactions and v3/v4
/// images/files plug in by adding a new case here and a matching value
/// in `Kind`. Existing clients reject unknown discriminators rather
/// than silently dropping content — fail loud, not soft.
enum MessagePayload: Codable, Sendable, Equatable {
    case text(TextMessage)

    enum Kind: String, Codable, Sendable {
        case text
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
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let message):
            try container.encode(Kind.text, forKey: .type)
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
        self.sentAt = Self.canonicalDate(from: sentAt)
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

    private static func canonicalDate(from date: Date) -> Date {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}

