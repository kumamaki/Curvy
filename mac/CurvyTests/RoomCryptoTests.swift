import CryptoKit
import Foundation
import Testing
@testable import Curvy

struct RoomCryptoTests {
    private func makeKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return Data(bytes)
    }

    private func makePayload(_ body: String = "hello world") -> MessagePayload {
        .text(TextMessage(
            sender: "kumamaki",
            body: body,
            replyTo: nil,
            sentAt: Date(timeIntervalSince1970: 1_750_000_000.123)
        ))
    }

    @Test func sealAndOpenRoundTrips() throws {
        let crypto = RoomCrypto()
        let key = makeKey()
        let payload = makePayload()
        let env = try crypto.seal(payload, with: key)
        let opened = try crypto.open(env, with: key)
        #expect(opened == payload)
    }

    @Test func roundTripPreservesReplyTo() throws {
        let crypto = RoomCrypto()
        let key = makeKey()
        let payload: MessagePayload = .text(TextMessage(
            sender: "alice",
            body: "responding to the thing",
            replyTo: "IC_kw1234567890",
            sentAt: Date()
        ))
        let env = try crypto.seal(payload, with: key)
        let opened = try crypto.open(env, with: key)
        #expect(opened == payload)
    }

    @Test func eachSealUsesAFreshNonce() throws {
        let crypto = RoomCrypto()
        let key = makeKey()
        let payload = makePayload()
        let a = try crypto.seal(payload, with: key)
        let b = try crypto.seal(payload, with: key)
        #expect(a.n != b.n, "nonces must differ across seals (AES-GCM nonce reuse is catastrophic)")
        #expect(a.c != b.c, "ciphertexts must differ across seals when nonces differ")
    }

    @Test func wrongKeyFailsToOpen() throws {
        let crypto = RoomCrypto()
        let env = try crypto.seal(makePayload(), with: makeKey())
        let wrongKey = makeKey()
        do {
            _ = try crypto.open(env, with: wrongKey)
            Issue.record("expected open to throw with wrong key")
        } catch RoomCrypto.CryptoError.openFailed {
            // expected
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }

    @Test func tamperedCiphertextFailsToOpen() throws {
        let crypto = RoomCrypto()
        let key = makeKey()
        let env = try crypto.seal(makePayload(), with: key)
        guard var ct = env.ciphertextData else {
            Issue.record("seal produced no decodable ciphertext")
            return
        }
        ct[0] ^= 0x01
        let tampered = MessageEnvelope(v: env.v, n: env.n, c: ct.base64EncodedString())
        do {
            _ = try crypto.open(tampered, with: key)
            Issue.record("expected open to throw on tampered ciphertext")
        } catch RoomCrypto.CryptoError.openFailed {
            // expected — AES-GCM tag mismatch
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }

    @Test func rejectsWrongKeyLengthOnSeal() {
        let crypto = RoomCrypto()
        let payload = makePayload()
        let shortKey = Data(repeating: 0, count: 16)
        do {
            _ = try crypto.seal(payload, with: shortKey)
            Issue.record("expected seal to throw on 16-byte key")
        } catch RoomCrypto.CryptoError.invalidKeyLength(let n) {
            #expect(n == 16)
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }

    @Test func envelopeRoundTripsThroughWireForm() throws {
        let crypto = RoomCrypto()
        let key = makeKey()
        let payload = makePayload("text that needs to survive a base64 round-trip")
        let env = try crypto.seal(payload, with: key)
        let wire = try env.encodeForWire()
        let decodedEnv = try MessageEnvelope.decode(wire)
        let opened = try crypto.open(decodedEnv, with: key)
        #expect(opened == payload)
    }

    @Test func sealedPayloadCarriesTypeDiscriminator() throws {
        let crypto = RoomCrypto()
        let key = makeKey()
        let payload: MessagePayload = .text(TextMessage(
            sender: "k", body: "hi", replyTo: nil, sentAt: Date()
        ))
        let env = try crypto.seal(payload, with: key)

        let symKey = SymmetricKey(data: key)
        let nonceBytes = try #require(env.nonceData)
        let combined = try #require(env.ciphertextData)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let tag = combined.suffix(16)
        let ct = combined.prefix(combined.count - 16)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let plaintext = try AES.GCM.open(box, using: symKey)
        let json = try #require(String(data: plaintext, encoding: .utf8))

        #expect(json.contains(#""type":"text""#))
        #expect(json.contains(#""sender":"k""#))
        #expect(json.contains(#""body":"hi""#))
        #expect(!json.contains("reply_to"), "reply_to must be omitted when nil, not encoded as null")
    }
}

