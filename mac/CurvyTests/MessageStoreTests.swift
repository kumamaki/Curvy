import Foundation
import SwiftData
import Testing
@testable import Curvy

@MainActor
struct MessageStoreTests {
    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        let schema = Schema([CachedMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    private let roomKey: Data = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return Data(bytes)
    }()

    private var invite: Invite {
        Invite(
            v: 1,
            token: "github_pat_test",
            roomKey: roomKey.base64EncodedString(),
            owner: "kumamaki",
            repo: "curvy-room"
        )
    }

    private func makePreferences() -> Preferences {
        let suite = "dev.kumamaki.Curvy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = Preferences(defaults: defaults)
        prefs.displayName = "tester"
        return prefs
    }

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

    /// Build a JSON array body that GitHub's `listComments` endpoint
    /// would return. Pre-seals each `payload` against the test room
    /// key so the polling path can exercise real decryption.
    private func issueCommentsJSON(
        _ entries: [(id: Int, payload: MessagePayload, createdAt: String, updatedAt: String)]
    ) throws -> Data {
        let crypto = RoomCrypto()
        let comments: [[String: Any]] = try entries.map { entry in
            let envelope = try crypto.seal(entry.payload, with: roomKey)
            let wire = try envelope.encodeForWire()
            return [
                "id": entry.id,
                "body": wire,
                "created_at": entry.createdAt,
                "updated_at": entry.updatedAt
            ]
        }
        return try JSONSerialization.data(withJSONObject: comments)
    }

    private func malformedCommentsJSON(
        _ entries: [(id: Int, body: String, createdAt: String, updatedAt: String)]
    ) throws -> Data {
        let comments: [[String: Any]] = entries.map { e in
            ["id": e.id, "body": e.body, "created_at": e.createdAt, "updated_at": e.updatedAt]
        }
        return try JSONSerialization.data(withJSONObject: comments)
    }

    private func cachedMessages(in context: ModelContext) throws -> [CachedMessage] {
        try context.fetch(FetchDescriptor<CachedMessage>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))
    }

    // MARK: - nextInterval (pure policy)

    @Test func nextIntervalFastWhenFocusedAndHealthy() {
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 0) == .seconds(5))
    }

    @Test func nextIntervalSlowWhenBackgroundedAndHealthy() {
        #expect(MessageStore.nextInterval(focused: false, consecutiveErrors: 0) == .seconds(15))
    }

    @Test func nextIntervalBacksOffOnErrors() {
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 1) == .seconds(5))
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 2) == .seconds(10))
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 3) == .seconds(20))
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 4) == .seconds(40))
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 5) == .seconds(80))
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 6) == .seconds(160))
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 7) == .seconds(300))
        #expect(MessageStore.nextInterval(focused: true, consecutiveErrors: 99) == .seconds(300))
    }

    // MARK: - pollOnce ingestion

    @Test func pollOnceIngestsTextComments() async throws {
        let context = try makeContext()
        let body = try issueCommentsJSON([
            (id: 100, payload: .text(TextMessage(
                sender: "alice",
                body: "hello",
                replyTo: nil,
                sentAt: Date(timeIntervalSince1970: 1_750_000_000)
            )), createdAt: "2026-05-06T12:00:00Z", updatedAt: "2026-05-06T12:00:00Z")
        ])
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (200, body) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()

        let cached = try cachedMessages(in: context)
        #expect(cached.count == 1)
        #expect(cached[0].id == 100)
        #expect(cached[0].kind == .text)
        #expect(cached[0].sender == "alice")
        #expect(cached[0].body == "hello")
        #expect(cached[0].replyTo == nil)
        #expect(store.status == .polling)
        #expect(store.consecutiveErrors == 0)
    }

    @Test func pollOnceMarksMalformedAsWeird() async throws {
        let context = try makeContext()
        let body = try malformedCommentsJSON([
            (id: 200, body: "this is not a valid base64 envelope at all !!!",
             createdAt: "2026-05-06T12:00:00Z", updatedAt: "2026-05-06T12:00:00Z")
        ])
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (200, body) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()

        let cached = try cachedMessages(in: context)
        #expect(cached.count == 1)
        #expect(cached[0].id == 200)
        #expect(cached[0].kind == .weird)
        #expect(!cached[0].body.isEmpty, "weird messages should retain a diagnostic body")
    }

    @Test func pollOnceMarksWrongKeyAsWeird() async throws {
        let context = try makeContext()

        // Seal against a *different* room key than the store will use.
        let foreignKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let crypto = RoomCrypto()
        let foreignEnv = try crypto.seal(.text(TextMessage(
            sender: "ghost", body: "from another room",
            replyTo: nil, sentAt: Date()
        )), with: foreignKey)
        let foreignWire = try foreignEnv.encodeForWire()

        let body = try malformedCommentsJSON([
            (id: 300, body: foreignWire,
             createdAt: "2026-05-06T12:00:00Z", updatedAt: "2026-05-06T12:00:00Z")
        ])
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (200, body) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()

        let cached = try cachedMessages(in: context)
        #expect(cached.count == 1)
        #expect(cached[0].kind == .weird)
    }

    @Test func pollOnceUpsertsExistingComment() async throws {
        let context = try makeContext()
        let v1 = try issueCommentsJSON([
            (id: 400, payload: .text(TextMessage(
                sender: "alice", body: "original",
                replyTo: nil, sentAt: Date(timeIntervalSince1970: 1_750_000_000)
            )), createdAt: "2026-05-06T12:00:00Z", updatedAt: "2026-05-06T12:00:00Z")
        ])
        let v2 = try issueCommentsJSON([
            (id: 400, payload: .text(TextMessage(
                sender: "alice", body: "edited",
                replyTo: nil, sentAt: Date(timeIntervalSince1970: 1_750_000_001)
            )), createdAt: "2026-05-06T12:00:00Z", updatedAt: "2026-05-06T12:30:00Z")
        ])

        let bodyBox = LockBox<Data>(v1)
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (200, bodyBox.get()) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()
        bodyBox.set(v2)
        await store.pollOnce()

        let cached = try cachedMessages(in: context)
        #expect(cached.count == 1, "upsert by id, not duplicate insert")
        #expect(cached[0].body == "edited")
    }

    @Test func pollOnceErrorsBumpBackoff() async throws {
        let context = try makeContext()
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (500, Data("server is sad".utf8)) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()
        #expect(store.consecutiveErrors == 1)
        await store.pollOnce()
        #expect(store.consecutiveErrors == 2)
        if case .error = store.status { /* ok */ } else {
            Issue.record("expected status to be .error after failures")
        }
    }

    @Test func successfulPollResetsBackoff() async throws {
        let context = try makeContext()
        let body = try issueCommentsJSON([])  // empty array, valid response
        let codeBox = LockBox<Int>(500)
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (codeBox.get(), body) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()
        await store.pollOnce()
        #expect(store.consecutiveErrors == 2)
        codeBox.set(200)
        await store.pollOnce()
        #expect(store.consecutiveErrors == 0)
        #expect(store.status == .polling)
    }

    // MARK: - send

    @Test func sendThrowsWhenNotStarted() async throws {
        let context = try makeContext()
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (200, Data("[]".utf8)) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        do {
            try await store.send(text: "hi")
            Issue.record("expected send to throw before start")
        } catch MessageStore.SendError.notStarted {
            // expected
        } catch {
            Issue.record("unexpected error: <\(error)>")
        }
    }

    @Test func sendPostsAndUpsertsLocally() async throws {
        let context = try makeContext()
        let captured = LockBox<URLRequest?>(nil)
        let response = """
        {
          "id": 555,
          "body": "ignored-by-test",
          "created_at": "2026-05-06T12:00:00Z",
          "updated_at": "2026-05-06T12:00:00Z"
        }
        """
        let prefs = makePreferences()
        prefs.displayName = "kumamaki"
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { request in
                captured.set(request)
                return (201, Data(response.utf8))
            }),
            preferences: prefs,
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        try await store.send(text: "ahoy", replyTo: "100")

        let request = try #require(captured.get())
        #expect(request.httpMethod == "POST")

        let cached = try cachedMessages(in: context)
        #expect(cached.count == 1)
        #expect(cached[0].id == 555)
        #expect(cached[0].kind == .text)
        #expect(cached[0].sender == "kumamaki")
        #expect(cached[0].body == "ahoy")
        #expect(cached[0].replyTo == "100")
    }

    // MARK: - send (image)

    @Test func sendImageHappyPath() async throws {
        let context = try makeContext()
        let prefs = makePreferences()
        prefs.displayName = "kumamaki"

        // Tiny one-pixel JPEG so we don't depend on real image bytes.
        let prepared = ImagePipeline.Prepared(
            bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            mime: "image/jpeg",
            width: 1,
            height: 1
        )

        let routes = LockBox<[String]>([])
        let putResponse = """
        {
          "content": { "sha": "abcsha", "path": "blobs/x.bin", "name": "x.bin", "size": 4 },
          "commit": { "sha": "deadbeef" }
        }
        """
        let postResponse = """
        {
          "id": 999,
          "body": "ignored",
          "created_at": "2026-05-06T12:00:00Z",
          "updated_at": "2026-05-06T12:00:00Z"
        }
        """
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { request in
                let path = request.url?.path ?? ""
                routes.set(routes.get() + [path])
                if path.contains("/contents/blobs/") {
                    return (201, Data(putResponse.utf8))
                } else if path.contains("/issues/") {
                    return (201, Data(postResponse.utf8))
                }
                return (404, Data())
            }),
            preferences: prefs,
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        try await store.sendImage(prepared: prepared, caption: "look", replyTo: nil)

        let cached = try cachedMessages(in: context)
        #expect(cached.count == 1)
        #expect(cached[0].id == 999)
        #expect(cached[0].kind == .image)
        #expect(cached[0].sender == "kumamaki")
        #expect(cached[0].body == "look")
        #expect(cached[0].assetSha == "abcsha")
        #expect(cached[0].assetPath == "blobs/x.bin")
        #expect(cached[0].imageMime == "image/jpeg")

        // PUT must come before POST — orphan GC requires that order.
        let routesList = routes.get()
        let putIdx = routesList.firstIndex { $0.contains("/contents/") } ?? -1
        let postIdx = routesList.firstIndex { $0.contains("/issues/") } ?? -1
        #expect(putIdx >= 0)
        #expect(postIdx > putIdx, "PUT contents must precede POST comment so orphan-GC has something to roll back")
    }

    @Test func sendImageGCsOrphanWhenCommentFails() async throws {
        let context = try makeContext()
        let prepared = ImagePipeline.Prepared(
            bytes: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            mime: "image/jpeg",
            width: 1,
            height: 1
        )
        let routes = LockBox<[(method: String, path: String)]>([])
        let putResponse = """
        {
          "content": { "sha": "orphansha", "path": "blobs/orphan.bin", "name": "orphan.bin", "size": 4 },
          "commit": { "sha": "deadbeef" }
        }
        """
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { request in
                let method = request.httpMethod ?? "?"
                let path = request.url?.path ?? ""
                routes.set(routes.get() + [(method, path)])
                if method == "PUT" && path.contains("/contents/") {
                    return (201, Data(putResponse.utf8))
                } else if method == "POST" && path.contains("/issues/") {
                    return (500, Data("server sad".utf8))  // fail the comment post
                } else if method == "DELETE" && path.contains("/contents/") {
                    return (200, Data("{}".utf8))
                }
                return (404, Data())
            }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        do {
            try await store.sendImage(prepared: prepared, caption: nil, replyTo: nil)
            Issue.record("expected sendImage to throw on comment failure")
        } catch {
            // expected
        }

        let routesList = routes.get()
        let methods = routesList.map(\.method)
        #expect(methods.contains("PUT"))
        #expect(methods.contains("POST"))
        #expect(methods.contains("DELETE"), "DELETE must fire to GC the orphaned blob")

        // Pending row should be gone.
        let cached = try cachedMessages(in: context)
        #expect(cached.isEmpty, "pending row should be deleted on send failure")
    }

    @Test func pollOnceIngestsImageComments() async throws {
        let context = try makeContext()
        let body = try issueCommentsJSON([
            (id: 800, payload: .image(ImageMessage(
                sender: "alice",
                assetPath: "blobs/foo.bin",
                assetSha: "abcsha",
                mime: "image/jpeg",
                keyB64: Data(repeating: 0x01, count: 32).base64EncodedString(),
                nonceB64: Data(repeating: 0x02, count: 12).base64EncodedString(),
                size: 100,
                width: 800,
                height: 600,
                caption: "look",
                replyTo: nil,
                sentAt: Date(timeIntervalSince1970: 1_750_000_000)
            )), createdAt: "2026-05-06T12:00:00Z", updatedAt: "2026-05-06T12:00:00Z")
        ])
        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { _ in (200, body) }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()

        let cached = try cachedMessages(in: context)
        #expect(cached.count == 1)
        #expect(cached[0].id == 800)
        #expect(cached[0].kind == .image)
        #expect(cached[0].sender == "alice")
        #expect(cached[0].body == "look")
        #expect(cached[0].assetPath == "blobs/foo.bin")
        #expect(cached[0].assetSha == "abcsha")
        #expect(cached[0].imageMime == "image/jpeg")
        #expect(cached[0].imageWidth == 800)
        #expect(cached[0].imageHeight == 600)
        // imageCachedAt is nil until BlobFetcher materializes the
        // bytes, which happens in a fire-and-forget Task we don't
        // synchronize on here.
    }

    // MARK: - watermark

    @Test func subsequentPollsUseLatestUpdatedAtAsSince() async throws {
        let context = try makeContext()
        let firstBody = try issueCommentsJSON([
            (id: 700, payload: .text(TextMessage(
                sender: "a", body: "one", replyTo: nil,
                sentAt: Date(timeIntervalSince1970: 1_750_000_000)
            )), createdAt: "2026-05-06T12:00:00Z", updatedAt: "2026-05-06T12:30:00Z")
        ])
        let bodyBox = LockBox<Data>(firstBody)
        let lastSince = LockBox<String?>(nil)

        let store = MessageStore(
            modelContext: context,
            github: GitHubClient(transport: mockTransport { request in
                let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                lastSince.set(q.first(where: { $0.name == "since" })?.value)
                return (200, bodyBox.get())
            }),
            preferences: makePreferences(),
            isFocused: { true }
        )
        store.start(invite: invite, beginPolling: false)
        await store.pollOnce()
        #expect(lastSince.get() == nil, "first poll should have no since")

        bodyBox.set(try issueCommentsJSON([]))
        await store.pollOnce()
        #expect(lastSince.get() == "2026-05-06T12:30:00Z", "second poll should pass the latest updatedAt")
    }
}

// MARK: - Helpers

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

