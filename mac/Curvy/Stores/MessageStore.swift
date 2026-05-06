import AppKit
import CryptoKit
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
    @ObservationIgnored private let blobFetcher: BlobFetcher
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
         blobFetcher: BlobFetcher? = nil,
         isFocused: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }) {
        self.modelContext = modelContext
        self.github = github
        self.crypto = crypto
        self.preferences = preferences
        self.blobFetcher = blobFetcher ?? BlobFetcher(github: github, modelContext: modelContext)
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

    // MARK: - Send (text)

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

    // MARK: - Send (image — v3)

    /// Send an encrypted image. Three round-trips on the wire, each
    /// against `api.github.com` only:
    ///
    /// 1. PUT the AES-GCM ciphertext to `blobs/<uuid>.bin` via the
    ///    Contents API (creates a commit on the `blobs` branch).
    /// 2. POST the room-key-sealed envelope to Issue #1's comments,
    ///    referencing the new file's `path` + `sha`.
    /// 3. (Failure path only) DELETE the orphan file if the comment
    ///    POST fails — keeps `curvy-room` from accreting unreferenced
    ///    ciphertext.
    ///
    /// Optimistic UI: a `.pendingImage` row appears immediately with
    /// the locally-stashed JPEG bytes so the bubble renders before
    /// either network call lands. On success the row updates in place
    /// to `.image` with the real GitHub comment ID. On failure the
    /// pending row is removed and the error rethrows.
    func sendImage(
        prepared: ImagePipeline.Prepared,
        caption: String?,
        replyTo: String? = nil
    ) async throws {
        guard let invite = currentInvite, let key = roomKey else {
            throw SendError.notStarted
        }
        let now = Date()
        let captionForBody = (caption?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        // Fresh per-file AES-GCM key + nonce. The room key never
        // touches the blob host: only this throwaway key does, and
        // it's wrapped inside the room-key-sealed envelope below.
        let perFileKey = SymmetricKey(size: .bits256)
        let perFileNonce = AES.GCM.Nonce()
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(prepared.bytes, using: perFileKey, nonce: perFileNonce)
        } catch {
            throw error
        }
        let ciphertext = sealed.ciphertext + sealed.tag

        let perFileKeyData = perFileKey.withUnsafeBytes { Data($0) }
        let keyB64 = perFileKeyData.base64EncodedString()
        let nonceB64 = Data(perFileNonce).base64EncodedString()

        // Stash the JPEG bytes locally before any network call so the
        // pending bubble can render immediately. Same cache directory
        // as confirmed images, but keyed by the negative pending ID so
        // it can't collide with a real path. We re-link to the real
        // path on commit.
        let pendingID = -Int.random(in: 1...Int.max)
        let pendingFilename = "pending-\(abs(pendingID)).jpg"
        let pendingCacheURL = BlobFetcher.cacheDirectory.appending(path: pendingFilename, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: BlobFetcher.cacheDirectory, withIntermediateDirectories: true)
            try prepared.bytes.write(to: pendingCacheURL, options: .atomic)
        } catch {
            logger.warning("couldn't stash pending image: \(error.localizedDescription, privacy: .public)")
            // Non-fatal — the bubble will just show a placeholder
            // until the first poll cycle materializes the real file.
        }

        let assetPath = "blobs/\(UUID().uuidString.lowercased()).bin"
        let pendingRow = CachedMessage(
            id: pendingID,
            kind: .pendingImage,
            sender: preferences.displayName,
            body: captionForBody ?? "",
            replyTo: replyTo,
            sentAt: now,
            createdAt: now,
            updatedAt: now,
            assetPath: assetPath,
            assetSha: nil, // not yet known — populated post-PUT
            imageMime: prepared.mime,
            imageWidth: prepared.width,
            imageHeight: prepared.height,
            imageKeyB64: keyB64,
            imageNonceB64: nonceB64,
            imageCachedAt: Date() // local sidecar lives at pendingCacheURL
        )
        modelContext.insert(pendingRow)
        try? modelContext.save()

        var assetSha: String?
        do {
            // 1. Upload ciphertext to the default branch at `blobs/
            //    <uuid>.bin`. On an empty repo (zero commits) this
            //    creates the initial commit. On a populated repo it
            //    appends a new commit. No separate branch — files
            //    live alongside any other repo content.
            let ref = try await github.putContent(
                invite: invite,
                path: assetPath,
                bytes: ciphertext
            )
            assetSha = ref.sha

            // 2. Build + seal + post the message envelope.
            let payload: MessagePayload = .image(ImageMessage(
                sender: preferences.displayName,
                assetPath: ref.path,
                assetSha: ref.sha,
                mime: prepared.mime,
                keyB64: keyB64,
                nonceB64: nonceB64,
                size: ciphertext.count,
                width: prepared.width,
                height: prepared.height,
                caption: captionForBody,
                replyTo: replyTo,
                sentAt: now
            ))
            do {
                let envelope = try crypto.seal(payload, with: key)
                let wire = try envelope.encodeForWire()
                let comment = try await github.postComment(invite: invite, body: wire)
                commitPendingImage(
                    pendingRow,
                    withRealComment: comment,
                    pendingCacheURL: pendingCacheURL,
                    assetPath: ref.path,
                    assetSha: ref.sha
                )
            } catch {
                // 3. Comment failed — orphan-GC the file we just
                //    uploaded. Best-effort; if the delete also fails
                //    we accept the orphan (unreadable without the
                //    per-file key, which only ever existed locally).
                logger.error("comment post failed after PUT, GC'ing <\(ref.path, privacy: .public)>: \(String(describing: error), privacy: .public)")
                if let sha = assetSha {
                    do {
                        try await github.deleteContent(
                            invite: invite,
                            path: ref.path,
                            sha: sha
                        )
                    } catch {
                        logger.error("orphan asset GC failed for <\(ref.path, privacy: .public)>: \(String(describing: error), privacy: .public)")
                    }
                }
                throw error
            }
        } catch {
            logger.error("sendImage failed at <\(assetPath, privacy: .public)>: \(String(describing: error), privacy: .public)")
            modelContext.delete(pendingRow)
            try? modelContext.save()
            try? FileManager.default.removeItem(at: pendingCacheURL)
            throw error
        }
    }

    /// Promote a pending image row to a confirmed `.image` row.
    /// Re-links the locally-stashed sidecar to its content-addressable
    /// final filename (`<uuid>.bin`) so the cache key matches what
    /// receivers will compute, and bumps the row to its real GitHub
    /// comment ID — same in-place id swap as `commitPending` for text.
    ///
    /// Same race handling as the text case: if the polling loop
    /// already inserted a row with the real id, drop the pending row
    /// instead of conflicting on `@Attribute(.unique)`.
    private func commitPendingImage(
        _ pendingRow: CachedMessage,
        withRealComment comment: GitHubClient.IssueComment,
        pendingCacheURL: URL,
        assetPath: String,
        assetSha: String
    ) {
        let realID = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == realID })
        let duplicate = (try? modelContext.fetch(descriptor))?.first

        // Move the sidecar JPEG to its content-addressable name so the
        // receiver-side cache lookup in `MessageRow` finds it.
        let finalCacheURL = BlobFetcher.cacheURL(for: assetPath)
        do {
            try? FileManager.default.removeItem(at: finalCacheURL)
            try FileManager.default.moveItem(at: pendingCacheURL, to: finalCacheURL)
        } catch {
            logger.warning("couldn't relink pending sidecar to <\(assetPath, privacy: .public)>: \(error.localizedDescription, privacy: .public)")
        }

        if let duplicate, duplicate.persistentModelID != pendingRow.persistentModelID {
            modelContext.delete(pendingRow)
        } else {
            pendingRow.id = realID
            pendingRow.kind = .image
            pendingRow.assetPath = assetPath
            pendingRow.assetSha = assetSha
            pendingRow.createdAt = comment.createdAt
            pendingRow.updatedAt = comment.updatedAt
            pendingRow.imageCachedAt = Date()
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
                ingest(comment: comment, invite: invite, key: key)
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

    private func ingest(comment: GitHubClient.IssueComment, invite: Invite, key: Data) {
        do {
            let envelope = try MessageEnvelope.decode(comment.body)
            let payload = try crypto.open(envelope, with: key)
            switch payload {
            case .text:
                upsertText(comment: comment, payload: payload)
            case .image(let image):
                upsertImage(comment: comment, image: image, invite: invite, key: key)
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

    private func upsertImage(
        comment: GitHubClient.IssueComment,
        image: ImageMessage,
        invite: Invite,
        key: Data
    ) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })

        let row: CachedMessage
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .image
            existing.sender = image.sender
            existing.body = image.caption ?? ""
            existing.replyTo = image.replyTo
            existing.sentAt = image.sentAt
            existing.updatedAt = comment.updatedAt
            existing.assetPath = image.assetPath
            existing.assetSha = image.assetSha
            existing.imageMime = image.mime
            existing.imageWidth = image.width
            existing.imageHeight = image.height
            existing.imageKeyB64 = image.keyB64
            existing.imageNonceB64 = image.nonceB64
            row = existing
        } else {
            let cached = CachedMessage(
                id: id,
                kind: .image,
                sender: image.sender,
                body: image.caption ?? "",
                replyTo: image.replyTo,
                sentAt: image.sentAt,
                createdAt: comment.createdAt,
                updatedAt: comment.updatedAt,
                assetPath: image.assetPath,
                assetSha: image.assetSha,
                imageMime: image.mime,
                imageWidth: image.width,
                imageHeight: image.height,
                imageKeyB64: image.keyB64,
                imageNonceB64: image.nonceB64,
                imageCachedAt: nil
            )
            modelContext.insert(cached)
            row = cached
        }
        try? modelContext.save()

        // Kick off the receive-side download + decrypt. Idempotent —
        // a no-op on cache hit, deduped against in-flight assets.
        blobFetcher.materialize(row, invite: invite, roomKey: key)
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

