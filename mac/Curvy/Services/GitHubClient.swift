import Foundation

/// Thin wrapper over GitHub's REST API. The endpoints v1 needs:
/// `verifyAccess` to gate onboarding, `listComments` to pull new
/// messages from the room issue, `postComment` to send one. v3 adds
/// the Contents API surface for encrypted image blobs: `putContent`,
/// `getContent`, `deleteContent`. Everything goes through
/// `api.github.com` only — we deliberately avoid `uploads.github.com`
/// and `*.githubusercontent.com` (except the API host itself) because
/// those are blocked on at least one of the friends' networks.
///
/// No shared mutable state, so this is a `Sendable` struct rather than
/// an actor. The transport closure is injected so tests can hand in
/// canned responses without standing up `URLProtocol`. The fine-grained
/// PAT travels with each request as part of the `Invite`; this layer
/// never reads from Keychain (that's `SessionStore`'s job).
struct GitHubClient: Sendable {
    /// Closure that performs an authenticated HTTP round-trip.
    /// Defaults to `URLSession.shared`; tests substitute an in-memory
    /// implementation.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum GitHubError: Error, CustomStringConvertible {
        case http(Int, String)
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case decoding(any Error)
        case invalidResponse
        case invalidURL
        case contentTooLargeForInline

        var description: String {
            switch self {
            case .http(let code, _) where code == 403: "the token can't access this repo (HTTP 403)"
            case .http(let code, _) where code == 404: "the repo doesn't exist or the token can't see it (HTTP 404)"
            case .http(let code, let body): "HTTP \(code): \(body)"
            case .unauthorized: "the token isn't valid (HTTP 401)"
            case .rateLimited(let after):
                if let after { "rate limited — retry after \(Int(after))s" }
                else { "rate limited" }
            case .decoding(let err): "couldn't decode GitHub's response (\(err))"
            case .invalidResponse: "GitHub returned a non-HTTP response"
            case .invalidURL: "could not construct a valid request URL"
            case .contentTooLargeForInline: "Contents API returned no inline content (file >1 MB) — caller must fall back to Git Blobs API"
            }
        }
    }

    /// One comment on the room issue. We deliberately do **not** decode
    /// `user.login` or any other GitHub-visible identity field — per the
    /// project's trust model, sender identity lives inside the encrypted
    /// payload, never on GitHub. Omitting the field at the type level
    /// makes accidental fallbacks impossible.
    ///
    /// `id` is GitHub's stable numeric comment ID. It's what
    /// `TextMessage.replyTo` references (stringified) so old messages
    /// stay addressable without a separate ID layer.
    struct IssueComment: Decodable, Sendable, Equatable {
        let id: Int
        let body: String
        let createdAt: Date
        let updatedAt: Date
    }

    /// Minimal issue metadata. Only the comment count matters here —
    /// it lets `MessageStore` compute which page holds the latest
    /// messages on first launch so history loads newest-first.
    struct IssueInfo: Decodable, Sendable {
        let comments: Int
    }

    /// Result of a successful `putContent` — what the Contents API
    /// returns inside the `content` object on a create or update.
    /// We pull only the SHA (needed for later DELETE / blobs GET) and
    /// the path (echo-back, useful for sanity checks). Everything else
    /// from the GitHub response is discarded.
    struct ContentRef: Sendable, Equatable {
        let path: String
        let sha: String
    }

    private let transport: Transport

    init(transport: @escaping Transport = { try await GitHubClient.session.data(for: $0) }) {
        self.transport = transport
    }

    // MARK: - Onboarding + comments (v1)

    /// Validates an `Invite` by hitting `GET /repos/:owner/:repo`. A
    /// 200 response means the token works and has access to the repo —
    /// exactly what onboarding needs to confirm.
    func verifyAccess(invite: Invite) async throws {
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)",
            token: invite.token
        )
        _ = try await execute(request)
    }

    /// Fetch basic metadata for an issue — specifically its comment count,
    /// which `MessageStore` uses on first launch to compute which page
    /// of comment history to seed from so the newest messages appear first.
    func issueInfo(invite: Invite, issue: Int = 1) async throws -> IssueInfo {
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)/issues/\(issue)",
            token: invite.token
        )
        let data = try await execute(request)
        do {
            return try Self.decoder.decode(IssueInfo.self, from: data)
        } catch {
            throw GitHubError.decoding(error)
        }
    }

    /// List comments on the room issue. Pass `since` to fetch only
    /// comments updated after a timestamp — that's how the polling loop
    /// stays incremental. Pass `page` and `perPage` to fetch a specific
    /// slice of history — used on first launch to seed the newest messages
    /// and by `loadOlderMessages` to page backwards through history.
    func listComments(
        invite: Invite,
        issue: Int = 1,
        since: Date? = nil,
        page: Int = 1,
        perPage: Int = 100
    ) async throws -> [IssueComment] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: "\(perPage)"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        if let since {
            // GitHub rejects fractional seconds on `since`. Default
            // ISO8601FormatStyle already omits them.
            let style = Date.ISO8601FormatStyle()
            query.append(URLQueryItem(name: "since", value: since.formatted(style)))
        }
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)/issues/\(issue)/comments",
            queryItems: query,
            token: invite.token
        )
        let data = try await execute(request)
        do {
            return try Self.decoder.decode([IssueComment].self, from: data)
        } catch {
            throw GitHubError.decoding(error)
        }
    }

    /// Post a comment to the room issue. `body` is the wire-form
    /// envelope (base64 of JSON), opaque to GitHub. Returns the created
    /// `IssueComment` so callers can capture the assigned ID for local
    /// caching without a follow-up GET.
    func postComment(invite: Invite, issue: Int = 1, body: String) async throws -> IssueComment {
        let payload = try Self.encoder.encode(["body": body])
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)/issues/\(issue)/comments",
            method: "POST",
            body: payload,
            token: invite.token
        )
        let data = try await execute(request)
        do {
            return try Self.decoder.decode(IssueComment.self, from: data)
        } catch {
            throw GitHubError.decoding(error)
        }
    }

    // MARK: - Contents API (v3)

    /// Create or update a file at `path`. The bytes are base64-encoded
    /// into the JSON body — that's the Contents API's only encoding,
    /// no raw-binary path. Returns the new file's SHA and path,
    /// captured into a small `ContentRef`.
    ///
    /// `branch` is nil by default, which uses the repository's default
    /// branch (`main` for fresh repos). **Even on an empty repo with
    /// zero commits**, this works — the Contents API creates the
    /// initial commit AND the file in one operation. Trying to write
    /// to a *named* branch that doesn't exist would fail; using the
    /// default branch sidesteps that bootstrap problem entirely. We
    /// deliberately don't isolate blobs onto a separate branch since
    /// `curvy-room` is bot-only and the 4-person model never opens
    /// the repo's web UI.
    ///
    /// `committer` is set to a synthetic identity rather than reading
    /// from the PAT owner's git config — keeps kumamaki's real email
    /// out of the commit log even in the private-repo case.
    ///
    /// On filename collision, this becomes an UPDATE, not an error.
    /// Callers should pass UUID-based paths to avoid the implicit
    /// update semantics.
    func putContent(
        invite: Invite,
        path: String,
        bytes: Data,
        branch: String? = nil,
        message: String = "blob"
    ) async throws -> ContentRef {
        var body: [String: Any] = [
            "message": message,
            "content": bytes.base64EncodedString(),
            "committer": [
                "name": "Curvy",
                "email": "noreply@curvy.local",
            ],
        ]
        if let branch {
            body["branch"] = branch
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)/contents/\(path)",
            method: "PUT",
            body: payload,
            token: invite.token
        )
        let data = try await execute(request)
        // GitHub's response shape: { content: { sha, path, ... },
        // commit: { sha, ... } }. We only need the file SHA.
        struct Envelope: Decodable {
            struct Content: Decodable {
                let sha: String
                let path: String
            }
            let content: Content
        }
        do {
            let env = try Self.decoder.decode(Envelope.self, from: data)
            return ContentRef(path: env.content.path, sha: env.content.sha)
        } catch {
            throw GitHubError.decoding(error)
        }
    }

    /// Read the bytes of `path` on `branch`. For files **≤ 1 MB** the
    /// Contents API returns base64 content inline — one round-trip.
    /// For larger files, the API responds with `encoding: "none"` and
    /// no content; we fall back to the Git Blobs API using the SHA
    /// reported in the same response.
    ///
    /// We pass `assetSha` directly when the caller already has it (the
    /// common case — it's stored in the message envelope). When non-
    /// nil, we skip the Contents API entirely and go straight to the
    /// Blobs API for a uniform code path. Saves bandwidth on the bytes
    /// we already know we want.
    func getContent(
        invite: Invite,
        path: String,
        branch: String? = nil,
        knownSha: String? = nil
    ) async throws -> Data {
        if let sha = knownSha {
            return try await getBlob(invite: invite, sha: sha)
        }

        var query: [URLQueryItem] = []
        if let branch {
            query.append(URLQueryItem(name: "ref", value: branch))
        }
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)/contents/\(path)",
            queryItems: query,
            token: invite.token
        )
        let data = try await execute(request)

        struct Response: Decodable {
            let content: String?
            let encoding: String?
            let sha: String
            let size: Int
        }
        let response: Response
        do {
            response = try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw GitHubError.decoding(error)
        }

        if response.encoding == "base64", let inline = response.content {
            // The Contents API wraps base64 at column 60 with embedded
            // newlines. `Data(base64Encoded:)` rejects whitespace by
            // default — `.ignoreUnknownCharacters` strips the wrap.
            guard let bytes = Data(base64Encoded: inline, options: .ignoreUnknownCharacters) else {
                throw GitHubError.decoding(NSError(domain: "Curvy.GitHubClient", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Contents API returned non-base64 content"
                ]))
            }
            return bytes
        }

        // File >1 MB: fall back to Blobs API using the SHA we just
        // learned. One extra round-trip, same `api.github.com` host.
        return try await getBlob(invite: invite, sha: response.sha)
    }

    /// Fetch a blob's bytes by SHA via the Git Blobs API. Always
    /// returns base64-encoded content regardless of size — we just
    /// strip the wrapping and decode. Goes through `api.github.com`,
    /// the only GitHub host we rely on.
    func getBlob(invite: Invite, sha: String) async throws -> Data {
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)/git/blobs/\(sha)",
            token: invite.token
        )
        let data = try await execute(request)
        struct BlobResponse: Decodable {
            let content: String
            let encoding: String
        }
        let response: BlobResponse
        do {
            response = try Self.decoder.decode(BlobResponse.self, from: data)
        } catch {
            throw GitHubError.decoding(error)
        }
        guard response.encoding == "base64" else {
            throw GitHubError.decoding(NSError(domain: "Curvy.GitHubClient", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Blobs API returned encoding <\(response.encoding)>, expected base64"
            ]))
        }
        guard let bytes = Data(base64Encoded: response.content, options: .ignoreUnknownCharacters) else {
            throw GitHubError.decoding(NSError(domain: "Curvy.GitHubClient", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Blobs API returned non-base64 content"
            ]))
        }
        return bytes
    }

    /// Delete a file at `path` on `branch`. The Contents API requires
    /// the file's current SHA in the request body — that's the
    /// optimistic-concurrency check, and why we always store the SHA
    /// alongside the path in the message envelope.
    ///
    /// 404 is swallowed (file already gone is not an error condition
    /// for orphan-GC).
    func deleteContent(
        invite: Invite,
        path: String,
        sha: String,
        branch: String? = nil,
        message: String = "blob-gc"
    ) async throws {
        var body: [String: Any] = [
            "message": message,
            "sha": sha,
            "committer": [
                "name": "Curvy",
                "email": "noreply@curvy.local",
            ],
        ]
        if let branch {
            body["branch"] = branch
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let request = try authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)/contents/\(path)",
            method: "DELETE",
            body: payload,
            token: invite.token
        )
        do {
            _ = try await execute(request)
        } catch GitHubError.http(let code, _) where code == 404 {
            // Already gone — fine.
        }
    }

    // MARK: - Internals

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401:
                throw GitHubError.unauthorized
            case 429:
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                    .flatMap { TimeInterval($0) }
                throw GitHubError.rateLimited(retryAfter: retryAfter)
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                throw GitHubError.http(http.statusCode, body)
            }
        }
        return data
    }

    private func authenticatedRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        token: String
    ) throws -> URLRequest {
        guard var components = URLComponents(string: "https://api.github.com\(path)") else {
            throw GitHubError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw GitHubError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder = JSONEncoder()
}

