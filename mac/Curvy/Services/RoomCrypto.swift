import CryptoKit
import Foundation
import os

/// AES-GCM seal/open against the 32-byte room key. Stateless — every
/// call is independent. `Sendable` struct rather than an actor for the
/// same reason as `GitHubClient`: there's no shared mutable state to
/// serialise, so the actor primitive would only add overhead.
///
/// Per-message nonces are generated fresh inside `seal`. Callers
/// **cannot** supply a nonce — that's deliberate. AES-GCM nonce reuse
/// under the same key collapses both confidentiality and integrity, so
/// the API doesn't expose the foot-cannon.
struct RoomCrypto: Sendable {
    enum CryptoError: Error, CustomStringConvertible {
        case invalidKeyLength(Int)
        case malformedEnvelope
        case openFailed
        case payloadDecodeFailed(any Error)
        case payloadEncodeFailed(any Error)

        var description: String {
            switch self {
            case .invalidKeyLength(let n): "room key must be 32 bytes, got \(n)"
            case .malformedEnvelope: "envelope nonce or ciphertext is missing or malformed"
            case .openFailed: "AES-GCM open failed — wrong key or tampered ciphertext"
            case .payloadDecodeFailed(let e): "decrypted plaintext didn't decode as MessagePayload: \(e)"
            case .payloadEncodeFailed(let e): "couldn't JSON-encode MessagePayload before sealing: \(e)"
            }
        }
    }

    /// Seal a payload into a fresh envelope. Generates a new random
    /// 12-byte nonce per call. The caller is responsible for posting
    /// `envelope.encodeForWire()` to GitHub.
    ///
    /// The `SymmetricKey` overload is preferred for the DM path so
    /// `RoomCrypto.deriveDMKey`'s result never leaves the
    /// `SymmetricKey` protected representation. The `Data` overload
    /// stays for the main-room path because the room key arrives from
    /// the invite as `Data` and round-tripping it through
    /// `SymmetricKey` at the call site is noise.
    func seal(_ payload: MessagePayload, with keyData: Data) throws -> MessageEnvelope {
        guard keyData.count == 32 else {
            throw CryptoError.invalidKeyLength(keyData.count)
        }
        return try seal(payload, with: SymmetricKey(data: keyData))
    }

    func seal(_ payload: MessagePayload, with key: SymmetricKey) throws -> MessageEnvelope {
        let keySize = key.bitCount
        guard keySize == 256 else {
            throw CryptoError.invalidKeyLength(keySize / 8)
        }
        let plaintext: Data
        do {
            plaintext = try Self.encoder.encode(payload)
        } catch {
            throw CryptoError.payloadEncodeFailed(error)
        }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let nonceBytes = Data(sealed.nonce)
        let ciphertextWithTag = sealed.ciphertext + sealed.tag
        return MessageEnvelope(
            v: MessageEnvelope.currentVersion,
            n: nonceBytes.base64EncodedString(),
            c: ciphertextWithTag.base64EncodedString()
        )
    }

    /// Open an envelope and decode its inner payload. Fails closed —
    /// any wrong key, tampered byte, or malformed plaintext throws
    /// instead of returning partial data.
    func open(_ envelope: MessageEnvelope, with keyData: Data) throws -> MessagePayload {
        guard keyData.count == 32 else {
            throw CryptoError.invalidKeyLength(keyData.count)
        }
        return try open(envelope, with: SymmetricKey(data: keyData))
    }

    func open(_ envelope: MessageEnvelope, with key: SymmetricKey) throws -> MessagePayload {
        guard key.bitCount == 256 else {
            throw CryptoError.invalidKeyLength(key.bitCount / 8)
        }
        guard let nonceBytes = envelope.nonceData, nonceBytes.count == 12,
              let combined = envelope.ciphertextData, combined.count >= 16 else {
            throw CryptoError.malformedEnvelope
        }
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let tag = combined.suffix(16)
        let ciphertext = combined.prefix(combined.count - 16)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            AppLog.crypto.error("AES-GCM open failed — wrong key or tampered ciphertext")
            throw CryptoError.openFailed
        }
        do {
            return try Self.decoder.decode(MessagePayload.self, from: plaintext)
        } catch {
            AppLog.crypto.error("payload decode failed: \(error.localizedDescription, privacy: .public)")
            throw CryptoError.payloadDecodeFailed(error)
        }
    }

    // MARK: - DM key derivation (v1.5)

    /// Derive the AES-GCM key for a DM channel between two users.
    ///
    /// Both endpoints compute the same 32-byte key from:
    ///   pairKey = HKDF<SHA-256>(
    ///       ikm:  X25519(myPriv, theirPub),
    ///       salt: "curvy-dm-v1",
    ///       info: sorted(myUserID, theirUserID) joined by ":")
    ///
    /// Sorting the IDs guarantees both sides reach the same `info`
    /// regardless of who is "me" — the pair (A, B) and (B, A) are the
    /// same channel. The static salt scopes derivation to this app +
    /// purpose so the same Curve25519 key could in principle be reused
    /// for non-DM purposes without weakening either domain.
    ///
    /// Throws if X25519 key agreement fails (it shouldn't for well-
    /// formed inputs). Returns raw `Data` rather than `SymmetricKey`
    /// so the result feeds directly into `seal/open`, which already
    /// take `keyData: Data`.
    static func deriveDMKey(
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        theirPublicKey: Curve25519.KeyAgreement.PublicKey,
        myUserID: UUID,
        theirUserID: UUID
    ) throws -> SymmetricKey {
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)
        let salt = Data("curvy-dm-v1".utf8)
        let sortedIDs = [myUserID, theirUserID]
            .map { $0.uuidString.lowercased() }
            .sorted()
            .joined(separator: ":")
        let info = Data(sortedIDs.utf8)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    // MARK: - Shared codecs

    /// `MessagePayload` and its inner types handle their own field-level
    /// encoding (e.g. `TextMessage.sentAt` rides the wire as Int64 ms),
    /// so the encoder needs no special date strategy. Default JSON
    /// settings keep this layer indifferent to payload internals.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}

