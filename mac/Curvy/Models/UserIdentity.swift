import CryptoKit
import Foundation

/// A single peer's public identity on the Curvy roster. Built from a
/// successfully decoded `.identity` announcement. Strictly value-typed
/// because the registry replaces entries wholesale on every fresher
/// announce.
///
/// `pubKey` is the raw 32-byte Curve25519 key-agreement public key.
/// We keep it as `Data` rather than `Curve25519.KeyAgreement.PublicKey`
/// so the value can be hashed, cached in SwiftData, and compared with
/// `==` cheaply; the typed key is reconstructed lazily on the rare
/// path that actually needs ECDH.
struct UserIdentity: Sendable, Hashable {
    let userID: UUID
    let displayName: String
    let pubKey: Data
    let announcedAt: Date

    /// Rebuilds the CryptoKit public key on demand. Throws if the
    /// stored bytes were corrupted or aren't a valid X25519 point.
    func keyAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubKey)
    }
}

/// Atomic Keychain payload for this device's DM identity. Encoded as
/// JSON and stored under `KeychainStore.Account.identityBundle` as a
/// single blob so a crash between writes can never leave the userID
/// and the private key out of sync.
///
/// `privKeyB64` is base64 of the raw 32-byte Curve25519 key-agreement
/// private key — the same bytes `Curve25519.KeyAgreement.PrivateKey.
/// rawRepresentation` exposes. We use base64 (not raw bytes) so the
/// whole record can ride in a single JSON document.
struct IdentityBundle: Codable, Sendable {
    let userID: UUID
    let privKeyB64: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case privKeyB64 = "priv_key"
    }
}

/// Wire shape of an `.identity` payload — what gets sealed into the
/// envelope and posted to the main room so every other client can
/// learn this device's pubkey + display name without leaking either
/// to GitHub.
///
/// Field encoding matches the rest of the wire format: snake_case
/// keys, `Date` as Int64 milliseconds since 1970 (so seal/open round-
/// trips are byte-exact), `pubKey` as base64 of the raw 32-byte X25519
/// public key.
///
/// Identities are last-write-wins keyed by `userID` — display-name
/// edits and key rotations both ride the same channel. Old announces
/// stay in history but the registry only honours the freshest per ID.
struct IdentityAnnounce: Codable, Sendable, Equatable {
    let userID: UUID
    let displayName: String
    let pubKey: Data
    let sentAt: Date

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
        case pubKey = "pub_key"
        case sentAt = "sent_at"
    }

    init(userID: UUID, displayName: String, pubKey: Data, sentAt: Date) {
        self.userID = userID
        self.displayName = displayName
        self.pubKey = pubKey
        let ms = Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
        self.sentAt = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let userID = try container.decode(UUID.self, forKey: .userID)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let pubKeyB64 = try container.decode(String.self, forKey: .pubKey)
        guard let pubKey = Data(base64Encoded: pubKeyB64), pubKey.count == 32 else {
            throw DecodingError.dataCorruptedError(
                forKey: .pubKey, in: container,
                debugDescription: "pub_key is not a 32-byte base64 X25519 public key"
            )
        }
        let ms = try container.decode(Int64.self, forKey: .sentAt)
        self.init(
            userID: userID,
            displayName: displayName,
            pubKey: pubKey,
            sentAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userID, forKey: .userID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(pubKey.base64EncodedString(), forKey: .pubKey)
        let ms = Int64((sentAt.timeIntervalSince1970 * 1000).rounded())
        try container.encode(ms, forKey: .sentAt)
    }
}

