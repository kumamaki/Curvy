import Foundation
import Testing
@testable import Curvy

struct MessageEnvelopeTests {
    @Test func roundTripsThroughBase64JSON() throws {
        let original = MessageEnvelope(
            v: 1,
            n: Data(repeating: 0xAB, count: 12).base64EncodedString(),
            c: Data(repeating: 0xCD, count: 32).base64EncodedString()
        )
        let wire = try original.encodeForWire()
        let decoded = try MessageEnvelope.decode(wire)
        #expect(decoded == original)
    }

    @Test func rejectsNonBase64() {
        #expect(throws: MessageEnvelope.DecodeError.notBase64) {
            try MessageEnvelope.decode("not base64 at all !!!@#$")
        }
    }

    @Test func rejectsMalformedJSON() {
        let notJSON = Data("hello world".utf8).base64EncodedString()
        #expect(throws: MessageEnvelope.DecodeError.malformedJSON) {
            try MessageEnvelope.decode(notJSON)
        }
    }

    @Test func rejectsUnsupportedVersion() {
        let n12 = Data(repeating: 0, count: 12).base64EncodedString()
        let c32 = Data(repeating: 0, count: 32).base64EncodedString()
        let badJSON = #"{"v":99,"n":"\#(n12)","c":"\#(c32)"}"#
        let wire = Data(badJSON.utf8).base64EncodedString()
        #expect(throws: MessageEnvelope.DecodeError.unsupportedVersion(99)) {
            try MessageEnvelope.decode(wire)
        }
    }

    @Test func rejectsBadNonceLength() throws {
        let env = MessageEnvelope(
            v: 1,
            n: Data(repeating: 0, count: 8).base64EncodedString(),
            c: Data(repeating: 0, count: 32).base64EncodedString()
        )
        let wire = try env.encodeForWire()
        #expect(throws: MessageEnvelope.DecodeError.invalidNonce) {
            try MessageEnvelope.decode(wire)
        }
    }

    @Test func rejectsTooShortCiphertext() throws {
        let env = MessageEnvelope(
            v: 1,
            n: Data(repeating: 0, count: 12).base64EncodedString(),
            c: Data(repeating: 0, count: 8).base64EncodedString()
        )
        let wire = try env.encodeForWire()
        #expect(throws: MessageEnvelope.DecodeError.invalidCiphertext) {
            try MessageEnvelope.decode(wire)
        }
    }

    @Test func ignoresWhitespaceInWireForm() throws {
        let env = MessageEnvelope(
            v: 1,
            n: Data(repeating: 0xAB, count: 12).base64EncodedString(),
            c: Data(repeating: 0xCD, count: 32).base64EncodedString()
        )
        let wire = try env.encodeForWire()
        let wrapped = "  \n\(wire)\n  "
        let decoded = try MessageEnvelope.decode(wrapped)
        #expect(decoded == env)
    }
}

