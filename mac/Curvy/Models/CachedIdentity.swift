import Foundation
import SwiftData

/// One row per known peer (and ourselves). Populated from `.identity`
/// payloads pulled out of the main room — `IdentityRegistry` upserts
/// here whenever it ingests a fresher announce for a given `userID`.
///
/// Persisted (rather than rebuilt each launch by re-scanning history)
/// so the sidebar can render the roster instantly on cold start and
/// DM key derivation has the peer's pubkey available before any new
/// poll has run.
///
/// `pubKey` is the raw 32-byte Curve25519 key-agreement public key,
/// matching `UserIdentity.pubKey`. We do not store the private key
/// here — that lives only in Keychain.
///
/// `announcedAt` is the sender-supplied timestamp from the announce
/// payload (Int64 ms on the wire, materialised back to `Date` here).
/// Last-write-wins is keyed on this field so a stale re-broadcast
/// can't overwrite a newer rename.
@Model
final class CachedIdentity {
    @Attribute(.unique) var userID: UUID
    var displayName: String
    var pubKey: Data
    var announcedAt: Date

    init(userID: UUID, displayName: String, pubKey: Data, announcedAt: Date) {
        self.userID = userID
        self.displayName = displayName
        self.pubKey = pubKey
        self.announcedAt = announcedAt
    }
}

