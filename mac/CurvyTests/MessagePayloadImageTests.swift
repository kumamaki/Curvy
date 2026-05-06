import Foundation
import Testing
@testable import Curvy

/// Wire-format tests for `MessagePayload.image` — the v3 addition. We
/// care about three properties that need to hold across every release:
///
/// - The polymorphic `type` discriminator routes correctly to
///   `.image` and round-trips through Codable.
/// - Snake-case field names (`asset_path`, `asset_sha`, `reply_to`,
///   `sent_at`) match what the inner JSON looks like — receivers on
///   other Macs must decode it.
/// - `sentAt` survives the Int64-millisecond wire encoding without
///   floating-point drift, the same property `TextMessage` already
///   guarantees.
struct MessagePayloadImageTests {
    private func makeImage(
        sender: String = "kumamaki",
        caption: String? = "look at this",
        replyTo: String? = nil,
        sentAt: Date = Date(timeIntervalSince1970: 1_750_000_000.123)
    ) -> ImageMessage {
        ImageMessage(
            sender: sender,
            assetPath: "blobs/abc123.bin",
            assetSha: "9e3ec56d3a2d4f8e9b1f7c5e2d8a0b3f1e6c9d4a",
            mime: "image/jpeg",
            keyB64: Data(repeating: 0x01, count: 32).base64EncodedString(),
            nonceB64: Data(repeating: 0x02, count: 12).base64EncodedString(),
            size: 1024,
            width: 1920,
            height: 1280,
            caption: caption,
            replyTo: replyTo,
            sentAt: sentAt
        )
    }

    @Test func imagePayloadRoundTripsThroughCodable() throws {
        let original: MessagePayload = .image(makeImage())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessagePayload.self, from: data)
        #expect(decoded == original)
    }

    @Test func wireKeysAreSnakeCase() throws {
        let payload: MessagePayload = .image(makeImage())
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        // JSONEncoder escapes forward slashes in strings (`blobs\/abc...`)
        // — that's valid JSON, both forms parse identically. Check
        // keys only, not the path value, to stay robust to that.
        #expect(json.contains(#""type":"image""#))
        #expect(json.contains(#""asset_path":"#))
        #expect(json.contains(#""asset_sha":"#))
        #expect(json.contains(#""sent_at":"#))
        // Camel-case escapees would be a regression — guard explicitly.
        #expect(!json.contains("assetPath"))
        #expect(!json.contains("assetSha"))
        #expect(!json.contains("sentAt"))
    }

    @Test func optionalFieldsOmittedWhenNil() throws {
        let payload: MessagePayload = .image(makeImage(caption: nil, replyTo: nil))
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("caption"))
        #expect(!json.contains("reply_to"))
    }

    @Test func sentAtSurvivesMillisecondRoundTrip() throws {
        let original: MessagePayload = .image(makeImage(
            sentAt: Date(timeIntervalSince1970: 1_750_000_000.123)
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessagePayload.self, from: data)
        guard case .image(let original) = original, case .image(let decoded) = decoded else {
            Issue.record("expected .image cases on both sides")
            return
        }
        // Both should be the same canonical Int64-ms-rounded Double —
        // not the input 1_750_000_000.123 (which loses precision once
        // it goes through Int64 ms).
        #expect(decoded.sentAt == original.sentAt)
    }

    @Test func unknownDiscriminatorThrows() {
        let weird = #"{"type":"reaction","emoji":"👍"}"#
        let data = Data(weird.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MessagePayload.self, from: data)
        }
    }

    @Test func textPayloadStillRoundTrips() throws {
        // Adding the .image case must not regress .text.
        let original: MessagePayload = .text(TextMessage(
            sender: "alice",
            body: "hello",
            replyTo: nil,
            sentAt: Date(timeIntervalSince1970: 1_750_000_000)
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessagePayload.self, from: data)
        #expect(decoded == original)
    }
}
