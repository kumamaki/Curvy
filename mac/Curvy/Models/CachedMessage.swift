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
///
/// Image-specific fields (`assetPath`, `assetSha`, `imageMime`, …)
/// are populated for `.image` and `.pendingImage` rows and nil
/// otherwise. The decrypted image bytes themselves live in
/// `~/Library/Caches/.../blobs/<basename of assetPath>`, not SwiftData
/// — the local cache path is content-addressable from `assetPath`, so
/// storing it would be redundant. `imageCachedAt` is bumped when the
/// local file lands; flipping that field is what triggers the UI to
/// re-render (SwiftData publishes the change, `@Query` re-fires).
///
/// Two image identifiers, on purpose: `assetPath` is what `getContent`
/// addresses via the GitHub Contents API; `assetSha` is what the Git
/// Blobs API GET takes (used for files >1 MB) and what Contents API
/// DELETE requires in its request body during orphan-GC.
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

    // Image-specific. All nil for text/weird/pending-text rows.
    var assetPath: String?
    var assetSha: String?
    var imageMime: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageKeyB64: String?
    var imageNonceB64: String?
    var imageCachedAt: Date?

    /// Reaction-specific. Stringified GitHub comment ID of the message
    /// this reaction (or revocation) targets. Nil for every other
    /// kind. The reaction's emoji rides in `body`, the reactor's name
    /// in `sender` — same shape as text/image reuse the same columns.
    var reactionTargetID: String?

    enum Kind: String {
        /// Real, server-confirmed text message — has a real GitHub comment id.
        case text
        /// Couldn't decrypt or decode — render as "weird message detected".
        case weird
        /// Optimistically-inserted local text message awaiting network
        /// confirmation. Has a random negative id so it can't collide
        /// with real GitHub ids (which are always positive). Replaced
        /// with `.text` once `postComment` returns.
        case pending
        /// Real, server-confirmed image message. The asset ciphertext
        /// lives on `curvy-room`'s `blobs` release; the local cache
        /// fills in asynchronously via `BlobFetcher`.
        case image
        /// Optimistic image send — sidecar bytes were stashed to the
        /// cache dir under the negative id so the bubble can render
        /// immediately without waiting on the upload round-trip.
        case pendingImage
        /// Reaction (an emoji applied to a target message). Filtered
        /// out of the bubble list at render time and grouped under
        /// the target by `ChatView.rows`.
        case reaction
        /// Revocation of a previously-sent reaction. Wins over a
        /// matching `.reaction` row when its `sentAt` is newer.
        case reactionRemove
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
         updatedAt: Date,
         assetPath: String? = nil,
         assetSha: String? = nil,
         imageMime: String? = nil,
         imageWidth: Int? = nil,
         imageHeight: Int? = nil,
         imageKeyB64: String? = nil,
         imageNonceB64: String? = nil,
         imageCachedAt: Date? = nil,
         reactionTargetID: String? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.sender = sender
        self.body = body
        self.replyTo = replyTo
        self.sentAt = sentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assetPath = assetPath
        self.assetSha = assetSha
        self.imageMime = imageMime
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageKeyB64 = imageKeyB64
        self.imageNonceB64 = imageNonceB64
        self.imageCachedAt = imageCachedAt
        self.reactionTargetID = reactionTargetID
    }
}

