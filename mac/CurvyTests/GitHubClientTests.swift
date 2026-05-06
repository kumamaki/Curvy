import Foundation
import Testing
@testable import Curvy

struct GitHubClientTests {
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

    // MARK: - verifyAccess

    @Test func verifyAccessSucceedsOn200() async throws {
        let client = GitHubClient(transport: mockTransport { _ in (200, Data()) })
        try await client.verifyAccess(invite: invite)
    }

    @Test func verifyAccessThrowsOn401() async {
        let client = GitHubClient(transport: mockTransport { _ in
            (401, Data(#"{"message":"bad creds"}"#.utf8))
        })
        do {
            try await client.verifyAccess(invite: invite)
            Issue.record("expected verifyAccess to throw on 401")
        } catch GitHubClient.GitHubError.http(let code, _) {
            #expect(code == 401)
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }

    @Test func verifyAccessThrowsOn404() async {
        let client = GitHubClient(transport: mockTransport { _ in (404, Data()) })
        do {
            try await client.verifyAccess(invite: invite)
            Issue.record("expected verifyAccess to throw on 404")
        } catch GitHubClient.GitHubError.http(let code, _) {
            #expect(code == 404)
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }

    // MARK: - listComments

    @Test func listCommentsHitsCorrectURL() async throws {
        let captured = LockBox<URLRequest?>(nil)
        let client = GitHubClient(transport: mockTransport { request in
            captured.set(request)
            return (200, Data("[]".utf8))
        })
        _ = try await client.listComments(invite: invite)
        let request = try #require(captured.get())
        let url = try #require(request.url)
        #expect(url.path == "/repos/kumamaki/curvy-room/issues/1/comments")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer github_pat_test")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func listCommentsOmitsSinceWhenNil() async throws {
        let captured = LockBox<URLRequest?>(nil)
        let client = GitHubClient(transport: mockTransport { request in
            captured.set(request)
            return (200, Data("[]".utf8))
        })
        _ = try await client.listComments(invite: invite, since: nil)
        let url = try #require(captured.get()?.url)
        #expect(url.query?.contains("since=") == false)
        #expect(url.query?.contains("per_page=100") == true)
    }

    @Test func listCommentsIncludesSinceWhenProvided() async throws {
        let captured = LockBox<URLRequest?>(nil)
        let client = GitHubClient(transport: mockTransport { request in
            captured.set(request)
            return (200, Data("[]".utf8))
        })
        // 1_750_000_000 epoch == 2025-06-15T15:06:40Z
        let since = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await client.listComments(invite: invite, since: since)
        let request = try #require(captured.get())
        let url = try #require(request.url)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let sinceItem = queryItems.first { $0.name == "since" }
        #expect(sinceItem?.value == "2025-06-15T15:06:40Z")
    }

    @Test func listCommentsParsesShape() async throws {
        let json = """
        [
          {
            "id": 3478291023,
            "body": "AAAA-base64-payload",
            "created_at": "2026-05-06T12:00:00Z",
            "updated_at": "2026-05-06T12:30:00Z",
            "user": {"login": "should-not-appear"}
          }
        ]
        """
        let client = GitHubClient(transport: mockTransport { _ in (200, Data(json.utf8)) })
        let comments = try await client.listComments(invite: invite)
        #expect(comments.count == 1)
        let c = comments[0]
        #expect(c.id == 3_478_291_023)
        #expect(c.body == "AAAA-base64-payload")
        let style = Date.ISO8601FormatStyle()
        #expect(c.createdAt == (try style.parse("2026-05-06T12:00:00Z")))
        #expect(c.updatedAt == (try style.parse("2026-05-06T12:30:00Z")))
    }

    @Test func listCommentsHandlesEmptyArray() async throws {
        let client = GitHubClient(transport: mockTransport { _ in (200, Data("[]".utf8)) })
        let comments = try await client.listComments(invite: invite)
        #expect(comments.isEmpty)
    }

    @Test func listCommentsThrowsDecodingErrorOnGarbage() async {
        let client = GitHubClient(transport: mockTransport { _ in
            (200, Data("not json at all".utf8))
        })
        do {
            _ = try await client.listComments(invite: invite)
            Issue.record("expected listComments to throw on bad JSON")
        } catch GitHubClient.GitHubError.decoding {
            // expected
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }

    // MARK: - postComment

    @Test func postCommentSendsBodyAndReturnsCreated() async throws {
        let captured = LockBox<URLRequest?>(nil)
        let response = """
        {
          "id": 9876,
          "body": "envelope-b64",
          "created_at": "2026-05-06T12:00:00Z",
          "updated_at": "2026-05-06T12:00:00Z"
        }
        """
        let client = GitHubClient(transport: mockTransport { request in
            captured.set(request)
            return (201, Data(response.utf8))
        })
        let result = try await client.postComment(invite: invite, body: "envelope-b64")

        let request = try #require(captured.get())
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/repos/kumamaki/curvy-room/issues/1/comments")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.httpBody)
        let bodyJSON = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        #expect(bodyJSON?["body"] == "envelope-b64")

        #expect(result.id == 9876)
        #expect(result.body == "envelope-b64")
    }

    @Test func postCommentThrowsOn422() async {
        let client = GitHubClient(transport: mockTransport { _ in
            (422, Data(#"{"message":"validation failed"}"#.utf8))
        })
        do {
            _ = try await client.postComment(invite: invite, body: "x")
            Issue.record("expected postComment to throw on 422")
        } catch GitHubClient.GitHubError.http(let code, let body) {
            #expect(code == 422)
            #expect(body.contains("validation failed"))
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }
}

// MARK: - Test helpers

/// Tiny lock-protected box for capturing values from inside `@Sendable`
/// transport closures. `nonisolated(unsafe)` would also work but a real
/// lock makes the concurrency story explicit.
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

