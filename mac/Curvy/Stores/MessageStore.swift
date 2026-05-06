import AppKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Long-lived store for the room's chat. Owns the polling loop, the
/// send path, and the SwiftData cache writes. The chat UI reads
/// messages from the cache via `@Query`; this store doesn't expose a
/// message list directly because @Query already gives the view a
/// reactive, ordered, filtered slice for free.
///
/// Lifecycle: `start(invite:)` after onboarding succeeds, `stop()` on
/// sign-out. The polling loop is a `Task` owned by this store and
/// cancelled on `stop()`.
///
/// Concurrency: this class is `@MainActor`, so the `Task` it spawns
/// inherits MainActor isolation. SwiftData reads/writes and AES-GCM
/// operations all run on MainActor; network I/O suspends the actor
/// via `await` so the main thread isn't blocked.
@MainActor
@Observable
final class MessageStore {
    enum Status: Equatable {
        case idle
        case polling
        case error(String)
    }

    enum SendError: Error, CustomStringConvertible {
        case notStarted
        var description: String { "MessageStore must be started before sending" }
    }

    private(set) var status: Status = .idle

    /// Read-only snapshot of the active display name. Used by the chat
    /// UI to compute `isMine` for bubble alignment. Reads through to
    /// `Preferences` without triggering observation — v1 has no UI to
    /// change the name mid-session, so a snapshot per render is fine.
    var displayName: String { preferences.displayName }

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let github: GitHubClient
    @ObservationIgnored private let crypto: RoomCrypto
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    @ObservationIgnored private let logger = Logger(subsystem: "dev.kumamaki.Curvy", category: "MessageStore")

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var currentInvite: Invite?
    @ObservationIgnored private var roomKey: Data?
    @ObservationIgnored private(set) var consecutiveErrors: Int = 0

    init(modelContext: ModelContext,
         github: GitHubClient = GitHubClient(),
         crypto: RoomCrypto = RoomCrypto(),
         preferences: Preferences = Preferences(),
         isFocused: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }) {
        self.modelContext = modelContext
        self.github = github
        self.crypto = crypto
        self.preferences = preferences
        self.isFocused = isFocused
    }

    // MARK: - Lifecycle

    /// Begin polling and accept sends. Idempotent: a second `start`
    /// cancels the previous loop and starts fresh with the new invite.
    ///
    /// `beginPolling` is `true` in production. Tests pass `false` to
    /// configure state without spawning the background loop, so they
    /// can drive `pollOnce()` synchronously without the loop racing
    /// for actor time on every `await`.
    func start(invite: Invite, beginPolling: Bool = true) {
        guard let key = invite.roomKeyData else {
            status = .error("invite has no decodable room key")
            return
        }
        currentInvite = invite
        roomKey = key
        consecutiveErrors = 0
        pollTask?.cancel()
        if beginPolling {
            pollTask = Task { [weak self] in
                await self?.runPollLoop()
            }
        }
    }

    /// Cancel the polling loop and clear in-memory secrets. Safe to
    /// call when not started.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        currentInvite = nil
        roomKey = nil
        consecutiveErrors = 0
        status = .idle
    }

    // MARK: - Send

    /// Seal `text` against the room key, post it as a comment on the
    /// room issue, and upsert the result into the local cache.
    ///
    /// Insertion is **optimistic**: a `.pending` row appears in the
    /// cache (and therefore the UI) before the network call returns,
    /// so the chat feels immediate. On success the pending row is
    /// deleted and a `.text` row with the real GitHub id replaces it.
    /// On failure the pending row is deleted and the error rethrows
    /// to the caller (which restores the draft text).
    func send(text: String, replyTo: String? = nil) async throws {
        guard let invite = currentInvite, let key = roomKey else {
            throw SendError.notStarted
        }
        let now = Date()
        let payload: MessagePayload = .text(TextMessage(
            sender: preferences.displayName,
            body: text,
            replyTo: replyTo,
            sentAt: now
        ))

        // Random negative id can't collide with real GitHub ids (which
        // are always positive 64-bit integers).
        let pendingID = -Int.random(in: 1...Int.max)
        let pendingRow = CachedMessage(
            id: pendingID,
            kind: .pending,
            sender: preferences.displayName,
            body: text,
            replyTo: replyTo,
            sentAt: now,
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(pendingRow)
        try? modelContext.save()

        do {
            let envelope = try crypto.seal(payload, with: key)
            let wire = try envelope.encodeForWire()
            let comment = try await github.postComment(invite: invite, body: wire)
            commitPending(pendingRow, withRealComment: comment)
        } catch {
            modelContext.delete(pendingRow)
            try? modelContext.save()
            throw error
        }
    }

    /// Promotes a pending row to a confirmed `.text` row by updating
    /// its fields **in place** — preserves `persistentModelID`, so
    /// SwiftUI's `ForEach` (keyed by that id) doesn't see a removal
    /// + insertion and therefore doesn't reanimate the bubble. Net
    /// effect: the bubble visibly "solidifies" as opacity goes from
    /// 0.65 → 1.0, no flicker.
    ///
    /// Handles a rare race: if the polling loop fired during our
    /// `await postComment` and already inserted a row with the same
    /// real id, we drop the pending row and let the polling-inserted
    /// one stand instead of conflicting on `@Attribute(.unique)`.
    private func commitPending(_ pendingRow: CachedMessage, withRealComment comment: GitHubClient.IssueComment) {
        let realID = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == realID })
        let duplicate = (try? modelContext.fetch(descriptor))?.first

        if let duplicate, duplicate.persistentModelID != pendingRow.persistentModelID {
            modelContext.delete(pendingRow)
        } else {
            pendingRow.id = realID
            pendingRow.kind = .text
            pendingRow.createdAt = comment.createdAt
            pendingRow.updatedAt = comment.updatedAt
        }
        try? modelContext.save()
    }

    // MARK: - Polling

    /// Single poll iteration. Public so tests can drive ingestion
    /// synchronously without standing up `runPollLoop`.
    func pollOnce() async {
        guard let invite = currentInvite, let key = roomKey else { return }
        do {
            let since = currentWatermark()
            let comments = try await github.listComments(invite: invite, since: since)
            for comment in comments {
                ingest(comment: comment, key: key)
            }
            consecutiveErrors = 0
            status = .polling
        } catch {
            consecutiveErrors += 1
            status = .error("\(error)")
        }
    }

    /// Pure scheduling policy — exposed static so tests can verify the
    /// schedule without spinning up an NSApp, a Task, or a sleep.
    /// Healthy: 5s when focused, 15s when backgrounded. Unhealthy:
    /// exponential backoff `5 → 10 → 20 → 40 → 80 → 160 → 300` capped.
    static func nextInterval(focused: Bool, consecutiveErrors: Int) -> Duration {
        if consecutiveErrors > 0 {
            let secs = min(5.0 * pow(2.0, Double(consecutiveErrors - 1)), 300)
            return .seconds(secs)
        }
        return focused ? .seconds(5) : .seconds(15)
    }

    private func runPollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            let interval = Self.nextInterval(
                focused: isFocused(),
                consecutiveErrors: consecutiveErrors
            )
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - Ingest

    private func ingest(comment: GitHubClient.IssueComment, key: Data) {
        do {
            let envelope = try MessageEnvelope.decode(comment.body)
            let payload = try crypto.open(envelope, with: key)
            switch payload {
            case .text:
                upsertText(comment: comment, payload: payload)
            }
        } catch {
            logger.warning("dropped comment <\(comment.id, privacy: .public)>: \(error.localizedDescription, privacy: .public)")
            upsertWeird(comment: comment, error: error)
        }
    }

    private func upsertText(comment: GitHubClient.IssueComment, payload: MessagePayload) {
        guard case .text(let text) = payload else { return }
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .text
            existing.sender = text.sender
            existing.body = text.body
            existing.replyTo = text.replyTo
            existing.sentAt = text.sentAt
            existing.updatedAt = comment.updatedAt
        } else {
            let cached = CachedMessage(
                id: id,
                kind: .text,
                sender: text.sender,
                body: text.body,
                replyTo: text.replyTo,
                sentAt: text.sentAt,
                createdAt: comment.createdAt,
                updatedAt: comment.updatedAt
            )
            modelContext.insert(cached)
        }
        try? modelContext.save()
    }

    private func upsertWeird(comment: GitHubClient.IssueComment, error: any Error) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .weird
            existing.body = "\(error)"
            existing.updatedAt = comment.updatedAt
        } else {
            let cached = CachedMessage(
                id: id,
                kind: .weird,
                sender: "",
                body: "\(error)",
                replyTo: nil,
                sentAt: comment.createdAt,
                createdAt: comment.createdAt,
                updatedAt: comment.updatedAt
            )
            modelContext.insert(cached)
        }
        try? modelContext.save()
    }

    private func currentWatermark() -> Date? {
        var descriptor = FetchDescriptor<CachedMessage>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.updatedAt
    }
}

