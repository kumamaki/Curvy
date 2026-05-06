import Foundation

/// Thin wrapper over GitHub's REST API. The endpoints v1 needs:
/// `verifyAccess` to gate onboarding, `listComments` to pull new
/// messages from the room issue, `postComment` to send one.
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
        case decoding(any Error)
        case invalidResponse

        var description: String {
            switch self {
            case .http(let code, _) where code == 401: "the token isn't valid (HTTP 401)"
            case .http(let code, _) where code == 403: "the token can't access this repo (HTTP 403)"
            case .http(let code, _) where code == 404: "the repo doesn't exist or the token can't see it (HTTP 404)"
            case .http(let code, let body): "HTTP \(code): \(body)"
            case .decoding(let err): "couldn't decode GitHub's response (\(err))"
            case .invalidResponse: "GitHub returned a non-HTTP response"
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

    private let transport: Transport

    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    /// Validates an `Invite` by hitting `GET /repos/:owner/:repo`. A
    /// 200 response means the token works and has access to the repo —
    /// exactly what onboarding needs to confirm.
    func verifyAccess(invite: Invite) async throws {
        let request = authenticatedRequest(
            path: "/repos/\(invite.owner)/\(invite.repo)",
            token: invite.token
        )
        _ = try await execute(request)
    }

    /// List comments on the room issue. Pass `since` to fetch only
    /// comments updated after a timestamp — that's how the polling
    /// actor stays incremental. Capped at 100 per request; pagination
    /// via Link headers is not yet implemented because a v1 room won't
    /// realistically deliver 100 messages between polls.
    func listComments(invite: Invite, issue: Int = 1, since: Date? = nil) async throws -> [IssueComment] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: "100")
        ]
        if let since {
            // GitHub rejects fractional seconds on `since`. Default
            // ISO8601FormatStyle already omits them.
            let style = Date.ISO8601FormatStyle()
            query.append(URLQueryItem(name: "since", value: since.formatted(style)))
        }
        let request = authenticatedRequest(
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
        let payload = try JSONEncoder().encode(["body": body])
        let request = authenticatedRequest(
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

    // MARK: - Internals

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(http.statusCode, body)
        }
        return data
    }

    private func authenticatedRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        token: String
    ) -> URLRequest {
        var components = URLComponents(string: "https://api.github.com\(path)")!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        var request = URLRequest(url: components.url!)
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

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

