import Foundation
import Testing
@testable import Curvy

/// Tests the v3 Contents API surface on `GitHubClient`. Same canned-
/// transport pattern as `GitHubClientTests` — we don't make real
/// network calls. We're proving:
/// - URL/path construction is right (no trailing-slash bugs, query
///   params encoded correctly)
/// - Required headers are present
/// - Response decoding picks up `sha` and `path`
/// - The size-based fallback logic in `getContent` correctly flips to
///   the Blobs API for files > 1 MB
/// - 404 is swallowed by `deleteContent` (orphan-GC tolerance)
struct GitHubClientContentsTests {
    private let invite = Invite(
        v: 1,
        token: "github_pat_test",
        roomKey: Data(repeating: 0, count: 32).base64EncodedString(),
        owner: "kumamaki",
        repo: "curvy-room"
    )

    private func mockTransport(
        _ responder: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> GitHubClient.Transport {
        return { request in
            let (code, data) = responder(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, response)
        }
    }

    // MARK: - putContent

    @Test func putContentSendsBase64InJSONBody() async throws {
        let captured = LockBox<URLRequest?>(nil)
        let response = """
        {
          "content": {
            "sha": "abc123",
            "path": "blobs/test.bin",
            "name": "test.bin",
            "size": 100
          },
          "commit": {
            "sha": "deadbeef"
          }
        }
        """
        let client = GitHubClient(transport: mockTransport { request in
            captured.set(request)
            return (201, Data(response.utf8))
        })

        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let ref = try await client.putContent(invite: invite, path: "blobs/test.bin", bytes: bytes)

        let request = try #require(captured.get())
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/repos/kumamaki/curvy-room/contents/blobs/test.bin")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_test")

        let bodyData = try #require(request.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJSON["content"] as? String == "3q2+7w==")
        // No branch param when caller doesn't specify one — uses repo
        // default. This is the only path that works on empty repos.
        #expect(bodyJSON["branch"] == nil)
        #expect(bodyJSON["message"] as? String == "blob")
        let committer = try #require(bodyJSON["committer"] as? [String: String])
        #expect(committer["name"] == "Curvy")
        #expect(committer["email"] == "noreply@curvy.local")

        #expect(ref.sha == "abc123")
        #expect(ref.path == "blobs/test.bin")
    }

    // MARK: - getContent / getBlob

    @Test func getContentInlineBase64() async throws {
        // Files <= 1 MB: Contents API returns base64 inline. We pass
        // knownSha = nil to exercise the Contents path (rather than the
        // shortcut to Blobs).
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let response = """
        {
          "content": "\(payload.base64EncodedString())",
          "encoding": "base64",
          "sha": "abc123",
          "size": \(payload.count)
        }
        """
        let client = GitHubClient(transport: mockTransport { _ in (200, Data(response.utf8)) })
        let bytes = try await client.getContent(invite: invite, path: "blobs/test.bin", knownSha: nil)
        #expect(bytes == payload)
    }

    @Test func getContentFallsBackToBlobsAPIForLargeFiles() async throws {
        // Files > 1 MB: Contents API returns encoding "none" with no
        // content. getContent must follow up with a Blobs API GET.
        let payload = Data(repeating: 0xAB, count: 100)
        let requestPaths = LockBox<[String]>([])
        let client = GitHubClient(transport: mockTransport { request in
            let path = request.url?.path ?? ""
            requestPaths.set(requestPaths.get() + [path])

            if path.contains("/contents/") {
                let response = """
                {
                  "content": null,
                  "encoding": "none",
                  "sha": "deadbeef",
                  "size": 2000000
                }
                """
                return (200, Data(response.utf8))
            } else if path.contains("/git/blobs/") {
                let response = """
                {
                  "content": "\(payload.base64EncodedString())",
                  "encoding": "base64"
                }
                """
                return (200, Data(response.utf8))
            }
            return (404, Data())
        })
        let bytes = try await client.getContent(invite: invite, path: "blobs/big.bin", knownSha: nil)
        #expect(bytes == payload)
        let captured = requestPaths.get()
        #expect(captured.contains { $0.contains("/contents/blobs/big.bin") })
        #expect(captured.contains { $0.contains("/git/blobs/deadbeef") })
    }

    @Test func getContentTakesShortcutWhenSHAKnown() async throws {
        // When the caller already has the SHA (the common case — it's
        // in the message envelope), getContent skips the Contents API
        // and goes straight to the Blobs API.
        let payload = Data([0x01, 0x02, 0x03])
        let captured = LockBox<URLRequest?>(nil)
        let client = GitHubClient(transport: mockTransport { request in
            captured.set(request)
            let response = """
            {
              "content": "\(payload.base64EncodedString())",
              "encoding": "base64"
            }
            """
            return (200, Data(response.utf8))
        })
        let bytes = try await client.getContent(invite: invite, path: "blobs/test.bin", knownSha: "abc123")
        #expect(bytes == payload)
        let url = try #require(captured.get()?.url)
        #expect(url.path == "/repos/kumamaki/curvy-room/git/blobs/abc123")
    }

    @Test func blobsAPIHandlesWrappedBase64() async throws {
        // GitHub's response wraps base64 at column 60. The decoder must
        // tolerate the embedded newlines.
        let payload = Data(repeating: 0xCC, count: 200)
        let raw = payload.base64EncodedString()
        // Inject newlines every 60 chars (matches what GitHub does).
        var wrapped = ""
        for (i, c) in raw.enumerated() {
            if i > 0 && i % 60 == 0 {
                wrapped.append("\n")
            }
            wrapped.append(c)
        }
        let response = """
        {
          "content": "\(wrapped.replacingOccurrences(of: "\n", with: "\\n"))",
          "encoding": "base64"
        }
        """
        let client = GitHubClient(transport: mockTransport { _ in (200, Data(response.utf8)) })
        let bytes = try await client.getBlob(invite: invite, sha: "abc")
        #expect(bytes == payload)
    }

    // MARK: - deleteContent

    @Test func deleteContentSendsSHAInBody() async throws {
        let captured = LockBox<URLRequest?>(nil)
        let client = GitHubClient(transport: mockTransport { request in
            captured.set(request)
            return (200, Data("{}".utf8))
        })
        try await client.deleteContent(invite: invite, path: "blobs/abc.bin", sha: "deadbeef")

        let request = try #require(captured.get())
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/repos/kumamaki/curvy-room/contents/blobs/abc.bin")

        let bodyData = try #require(request.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJSON["sha"] as? String == "deadbeef")
        #expect(bodyJSON["branch"] == nil)
    }

    @Test func deleteContentSwallows404() async throws {
        // Orphan-GC tolerance: if the file's already gone, that's fine.
        let client = GitHubClient(transport: mockTransport { _ in (404, Data()) })
        try await client.deleteContent(invite: invite, path: "blobs/gone.bin", sha: "abc")
        // No throw → success.
    }

    @Test func deleteContentBubblesNon404Errors() async {
        let client = GitHubClient(transport: mockTransport { _ in
            (403, Data(#"{"message":"forbidden"}"#.utf8))
        })
        do {
            try await client.deleteContent(invite: invite, path: "blobs/x.bin", sha: "abc")
            Issue.record("expected 403 to throw")
        } catch GitHubClient.GitHubError.http(let code, _) {
            #expect(code == 403)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - Test helpers (shared with GitHubClientTests)

private final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) { self.value = initial }

    func set(_ v: T) {
        lock.lock(); defer { lock.unlock() }
        value = v
    }

    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
