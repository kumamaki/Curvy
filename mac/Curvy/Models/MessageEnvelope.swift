import Foundation

/// The wire-level wrapper around one comment body on the room issue
/// in `curvy-room` (Issue #1 in Release, Issue #2 in Debug — see
/// `RoomConfig`). Three required fields:
///
/// ```
/// {
///   "v": 1,
///   "n": "<base64 12-byte AES-GCM nonce>",
///   "c": "<base64 ciphertext concatenated with the 16-byte tag>"
/// }
/// ```
///
/// The whole envelope is JSON-encoded and base64'd a second time so it
/// survives GitHub's comment storage cleanly. Inside the ciphertext is
/// a JSON-encoded `MessagePayload`.
///
/// This type is the wire shape only; sealing and opening live in
/// `RoomCrypto`. The split keeps the network/storage layer free of
/// `CryptoKit` and lets us test wire-format changes independently of
/// the cipher.
struct MessageEnvelope: Codable, Sendable, Equatable {
    let v: Int
    let n: String
    let c: String

    static let currentVersion = 1

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notBase64
        case malformedJSON
        case unsupportedVersion(Int)
        case invalidNonce
        case invalidCiphertext

        var description: String {
            switch self {
            case .notBase64: "comment body isn't valid base64"
            case .malformedJSON: "envelope JSON is malformed"
            case .unsupportedVersion(let v): "envelope version \(v) is not understood by this build (expected \(currentVersion))"
            case .invalidNonce: "envelope nonce isn't 12 bytes once decoded"
            case .invalidCiphertext: "envelope ciphertext+tag is too short to be valid AES-GCM output"
            }
        }
    }

    var nonceData: Data? {
        Data(base64Encoded: n)
    }

    var ciphertextData: Data? {
        Data(base64Encoded: c)
    }

    /// Decode a comment body (the outer base64 string GitHub stores)
    /// into a typed envelope. Validates the version, the nonce length,
    /// and that the ciphertext is at least long enough to hold an
    /// AES-GCM tag. The seal/open round-trip is `RoomCrypto`'s job.
    static func decode(_ commentBody: String) throws -> MessageEnvelope {
        let cleaned = commentBody
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
        guard let json = Data(base64Encoded: cleaned) else {
            throw DecodeError.notBase64
        }
        let envelope: MessageEnvelope
        do {
            envelope = try Self.decoder.decode(MessageEnvelope.self, from: json)
        } catch {
            throw DecodeError.malformedJSON
        }
        guard envelope.v == currentVersion else {
            throw DecodeError.unsupportedVersion(envelope.v)
        }
        guard let nonce = envelope.nonceData, nonce.count == 12 else {
            throw DecodeError.invalidNonce
        }
        guard let ct = envelope.ciphertextData, ct.count >= 16 else {
            throw DecodeError.invalidCiphertext
        }
        return envelope
    }

    /// Encode to the outer base64 string that gets posted as the
    /// comment body. Inverse of `decode(_:)`.
    func encodeForWire() throws -> String {
        let json = try Self.encoder.encode(self)
        return json.base64EncodedString()
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()
}

