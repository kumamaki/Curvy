import Foundation
import SwiftData

/// One message in the room, persisted locally so it survives app
/// restart and so the UI can render via `@Query` without re-fetching
/// from GitHub on every launch.
///
/// `id` is GitHub's stable comment ID — the unique key into the cache
/// and what `replyTo` references (stringified). All other fields come
/// either from inside the decrypted ciphertext (sender/body/replyTo/
/// sentAt) or from GitHub's authoritative metadata (createdAt,
/// updatedAt). The cache stores both timestamps because we order by
/// `createdAt` (server-authoritative, monotonic, immune to clock skew)
/// but display `sentAt` (sender-authoritative, matches what the sender
/// saw locally when they hit send).
///
/// `kind` distinguishes well-formed messages from "weird" entries — a
/// comment we couldn't decrypt or decode. They stay in the cache
/// rather than being dropped so the UI can render a "weird message
/// detected" affordance, preserving the comment ID for context.
@Model
final class CachedMessage {
    @Attribute(.unique) var id: Int
    var kindRaw: String
    var sender: String
    var body: String
    var replyTo: String?
    var sentAt: Date
    var createdAt: Date
    var updatedAt: Date

    enum Kind: String {
        /// Real, server-confirmed message — has a real GitHub comment id.
        case text
        /// Couldn't decrypt or decode — render as "weird message detected".
        case weird
        /// Optimistically-inserted local message awaiting network
        /// confirmation. Has a random negative id so it can't collide
        /// with real GitHub ids (which are always positive). Replaced
        /// with `.text` once `postComment` returns.
        case pending
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .weird }
        set { kindRaw = newValue.rawValue }
    }

    init(id: Int,
         kind: Kind,
         sender: String,
         body: String,
         replyTo: String?,
         sentAt: Date,
         createdAt: Date,
         updatedAt: Date) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.sender = sender
        self.body = body
        self.replyTo = replyTo
        self.sentAt = sentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

