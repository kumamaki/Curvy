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
/// Concurrency: this class is `@MainActor`. SwiftData reads/writes run on
/// MainActor. AES-GCM decryption runs concurrently on the cooperative pool
/// via `withTaskGroup` inside `pollOnce` — only the resulting SwiftData
/// writes return to MainActor. Network I/O suspends the actor via `await`.
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
    /// True when pages of history older than the initial seed still
    /// exist on GitHub. Drives the top-of-list spinner in ChatView.
    private(set) var hasOlderMessages: Bool = false
    /// True while `loadOlderMessages()` is running. ChatView uses this
    /// to show a spinner and prevent double-triggering on scroll.
    private(set) var isLoadingOlderMessages: Bool = false

    /// Number of cached, well-formed messages from someone other than
    /// the current user with `createdAt` strictly newer than the
    /// stored read watermark. Drives the dock badge label and is
    /// available to any view that wants to render an unread count.
    private(set) var unreadCount: Int = 0

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
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    @ObservationIgnored private let logger = AppLog.store

    @ObservationIgnored private let historyPerPage = 50

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var currentInvite: Invite?
    @ObservationIgnored private var roomKey: Data?
    @ObservationIgnored private(set) var consecutiveErrors: Int = 0
    // Tracks comment IDs for which a notification has already been posted
    // this session. Prevents duplicate banners when GitHub's `since`
    // parameter re-delivers the boundary message on every poll.
    @ObservationIgnored private var notifiedCommentIDs: Set<String> = []

    init(modelContext: ModelContext,
         github: GitHubClient = GitHubClient(),
         crypto: RoomCrypto = RoomCrypto(),
         preferences: Preferences = Preferences(),
         blobFetcher: BlobFetcher? = nil,
         notifier: Notifier = .live,
         isFocused: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }) {
        self.modelContext = modelContext
        self.github = github
        self.crypto = crypto
        self.preferences = preferences
        self.blobFetcher = blobFetcher ?? BlobFetcher(github: github, modelContext: modelContext)
        self.notifier = notifier
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

        // First-ever launch: baseline the read watermark so historical
        // content already in the room (or about to land via initial
        // sync) doesn't trigger a wave of notifications. We pick the
        // newest `createdAt` already in the cache, falling back to
        // `now` if the cache is empty — server timestamps for any
        // existing room content will be older than `now`, so initial
        // sync stays silent.
        if preferences.lastReadCreatedAt == nil {
            preferences.lastReadCreatedAt = latestCreatedAt() ?? Date()
        }
        refreshUnread()

        // If the cache was wiped (e.g. nuke-keychain) but UserDefaults
        // still has a stale page cursor, reset so the seed reruns.
        if preferences.oldestPageFetched > 0 && latestCreatedAt() == nil {
            preferences.oldestPageFetched = 0
        }
        hasOlderMessages = preferences.oldestPageFetched > 1

        if beginPolling {
            pollTask = Task { [weak self] in
                await self?.seedInitialHistoryIfNeeded()
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
        unreadCount = 0
        hasOlderMessages = false
        isLoadingOlderMessages = false
        notifiedCommentIDs.removeAll()
        notifier.setBadge(nil)
        notifier.clearDelivered()
    }

    // MARK: - Read state

    /// Mark every cached message as read: bump the watermark to the
    /// newest `createdAt`, drop any banners still sitting in
    /// Notification Center, and clear the dock badge. Called by
    /// `ChatView` when the window becomes the user's focus.
    func markRead() {
        if let latest = latestCreatedAt() {
            preferences.lastReadCreatedAt = latest
        }
        notifiedCommentIDs.removeAll()
        notifier.clearDelivered()
        refreshUnread()
    }

    private func refreshUnread() {
        let me = preferences.displayName
        let watermark = preferences.lastReadCreatedAt
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate {
                ($0.kindRaw == "text" || $0.kindRaw == "image") && $0.sender != me
            }
        )
        let candidates = (try? modelContext.fetch(descriptor)) ?? []
        // createdAt > watermark filter stays in Swift — optional comparisons
        // in SwiftData predicates are error-prone across versions.
        let count = watermark == nil
            ? candidates.count
            : candidates.filter { $0.createdAt > watermark! }.count
        unreadCount = count
        notifier.setBadge(badgeLabel(for: count))
    }

    private func badgeLabel(for count: Int) -> String? {
        if count <= 0 { return nil }
        if count > 99 { return "99+" }
        return String(count)
    }

    private func latestCreatedAt() -> Date? {
        var descriptor = FetchDescriptor<CachedMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.createdAt
    }

    /// Distinct sender names currently in the cache, plus the local
    /// user. Used by the body-text mention resolver on send and by the
    /// cold-start fallback in `announceIfNeeded`.
    private func currentKnownSenders() -> [String] {
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { !$0.sender.isEmpty }
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        var set = Set(rows.map(\.sender))
        set.insert(preferences.displayName)
        return set.sorted()
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
        // Body is the source of truth for mention targets — we resolve
        // `@<token>` (either the handle "Mehdi" or the full name
        // "Mehdi Khaledi") against the live cache of known senders at
        // send time. The wire carries canonical full names; `.map(\.name)`
        // strips the handle field used only by the renderer.
        let matches = MentionResolver.resolve(
            in: text,
            against: currentKnownSenders()
        )
        let mentions: [String]? = matches.isEmpty ? nil : matches.map(\.name)
        let payload: MessagePayload = .text(TextMessage(
            sender: preferences.displayName,
            body: text,
            replyTo: replyTo,
            mentions: mentions,
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
            mentions: mentions,
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
    /// 2. POST the room-key-sealed envelope to the room issue's
    ///    comments (see `RoomConfig`), referencing the new file's
    ///    `path` + `sha`.
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
        let pendingCacheURL: URL
        do {
            pendingCacheURL = try BlobFetcher.stashPending(filename: pendingFilename, data: prepared.bytes)
        } catch {
            logger.warning("couldn't stash pending image: \(error.localizedDescription, privacy: .public)")
            // Non-fatal — the bubble will just show a placeholder
            // until the first poll cycle materializes the real file.
            pendingCacheURL = BlobFetcher.cacheDirectory.appending(path: pendingFilename, directoryHint: .notDirectory)
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
        do {
            try BlobFetcher.relocateSidecar(from: pendingCacheURL, toAssetPath: assetPath)
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
            let since = pollCursor()
            let comments = try await github.listComments(invite: invite, since: since)
            await decryptAndIngest(comments, invite: invite, key: key)
            consecutiveErrors = 0
            status = .polling
        } catch {
            consecutiveErrors += 1
            status = .error("\(error)")
        }
    }

    /// Fetch the last `historyPerPage` messages on first launch.
    /// Runs once before the poll loop starts, so by the time the first
    /// incremental poll fires, `pollCursor()` already has a value and
    /// the poll only fetches messages newer than the seed.
    private func seedInitialHistoryIfNeeded() async {
        guard let invite = currentInvite, let key = roomKey else { return }
        guard preferences.oldestPageFetched == 0 else { return }

        do {
            let info = try await github.issueInfo(invite: invite)
            guard info.comments > 0 else {
                preferences.oldestPageFetched = 1
                hasOlderMessages = false
                return
            }
            let lastPage = max(1, Int(ceil(Double(info.comments) / Double(historyPerPage))))
            let comments = try await github.listComments(
                invite: invite,
                page: lastPage,
                perPage: historyPerPage
            )
            await decryptAndIngest(comments, invite: invite, key: key)
            preferences.oldestPageFetched = lastPage
            hasOlderMessages = lastPage > 1
        } catch {
            logger.warning("history seed failed: \(String(describing: error), privacy: .public)")
            // Best-effort fallback: mark as seeded at page 1 so the
            // poll loop takes over with since:nil on the next cycle.
            preferences.oldestPageFetched = 1
            hasOlderMessages = false
        }
    }

    /// Load the next older page of history and prepend it to the cache.
    /// Called by `ChatView` when the user scrolls near the top of the list.
    func loadOlderMessages() async {
        guard let invite = currentInvite, let key = roomKey else { return }
        guard !isLoadingOlderMessages, preferences.oldestPageFetched > 1 else { return }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        let targetPage = preferences.oldestPageFetched - 1
        do {
            let comments = try await github.listComments(
                invite: invite,
                page: targetPage,
                perPage: historyPerPage
            )
            await decryptAndIngest(comments, invite: invite, key: key)
            preferences.oldestPageFetched = targetPage
            hasOlderMessages = targetPage > 1
        } catch {
            logger.warning("loadOlderMessages page <\(targetPage, privacy: .public)> failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Decrypt `comments` concurrently off the main thread and upsert
    /// the results into the SwiftData cache. Shared by `pollOnce`,
    /// `seedInitialHistoryIfNeeded`, and `loadOlderMessages`.
    private func decryptAndIngest(
        _ comments: [GitHubClient.IssueComment],
        invite: Invite,
        key: Data
    ) async {
        let localCrypto = crypto
        let decrypted: [(GitHubClient.IssueComment, MessagePayload)] = await withTaskGroup(
            of: (GitHubClient.IssueComment, MessagePayload)?.self
        ) { group in
            for comment in comments {
                group.addTask {
                    guard let envelope = try? MessageEnvelope.decode(comment.body),
                          let payload = try? localCrypto.open(envelope, with: key)
                    else { return nil }
                    return (comment, payload)
                }
            }
            var results: [(GitHubClient.IssueComment, MessagePayload)] = []
            for await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }

        let decryptedIDs = Set(decrypted.map { $0.0.id })
        for (comment, payload) in decrypted {
            ingestDecrypted(comment: comment, payload: payload, invite: invite, key: key)
        }
        for comment in comments where !decryptedIDs.contains(comment.id) {
            logger.warning("dropped comment <\(comment.id, privacy: .public)>: decryption failed")
            upsertWeird(comment: comment, error: DecryptError.failed)
        }
        try? modelContext.save()
    }

    private enum DecryptError: Error {
        case failed
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

    private func ingestDecrypted(comment: GitHubClient.IssueComment, payload: MessagePayload, invite: Invite, key: Data) {
        switch payload {
        case .text(let text):
            upsertText(comment: comment, payload: payload)
            announceIfNeeded(
                commentID: comment.id,
                createdAt: comment.createdAt,
                sender: text.sender,
                preview: text.body,
                mentions: text.mentions
            )
        case .image(let image):
            upsertImage(comment: comment, image: image, invite: invite, key: key)
            announceIfNeeded(
                commentID: comment.id,
                createdAt: comment.createdAt,
                sender: image.sender,
                preview: imagePreview(caption: image.caption)
            )
        case .reaction(let reaction):
            upsertReaction(comment: comment, reaction: reaction)
        case .reactionRemove(let removal):
            upsertReactionRemove(comment: comment, removal: removal)
        }
    }

    /// Decide whether a freshly-ingested message should fire a local
    /// notification or silently advance the read watermark. The split
    /// is by app focus: if the user is looking at Curvy, we treat the
    /// arrival as "read on sight" and bump the watermark; if not, we
    /// post a banner and let the dock badge tick up.
    ///
    /// Skips messages from the current user (you don't notify
    /// yourself) and any message whose `createdAt` is at or below the
    /// existing watermark — that's how out-of-order delivery and
    /// retries from the polling loop stay quiet.
    private func announceIfNeeded(
        commentID: Int,
        createdAt: Date,
        sender: String,
        preview: String,
        mentions: [String]? = nil
    ) {
        if sender == preferences.displayName { return }
        if let watermark = preferences.lastReadCreatedAt, createdAt <= watermark {
            return
        }
        if isFocused() {
            let watermark = preferences.lastReadCreatedAt ?? .distantPast
            preferences.lastReadCreatedAt = max(watermark, createdAt)
        } else {
            let idKey = String(commentID)
            // GitHub's `since` param is inclusive — the boundary message
            // is re-delivered on every poll. Guard here so a backgrounded
            // re-ingest of the same comment doesn't stack a second banner.
            guard !notifiedCommentIDs.contains(idKey) else {
                refreshUnread()
                return
            }
            let me = preferences.displayName
            // Cold-start fallback: if the sender's cache was empty
            // when they typed `@MyName`, the wire shipped `mentions:
            // nil`. Re-resolve against this client's known senders so
            // the notification path stays symmetric with the receiver-
            // side body highlight.
            let mentionsMe: Bool = {
                if let m = mentions { return m.contains(me) }
                return MentionResolver
                    .resolve(in: preview, against: currentKnownSenders())
                    .contains { $0.name == me }
            }()
            notifiedCommentIDs.insert(idKey)
            if mentionsMe {
                notifier.postMention(idKey, sender, preview)
            } else {
                notifier.post(idKey, sender, preview)
            }
        }
        refreshUnread()
    }

    /// One-line preview text for an image notification. We don't ship
    /// the actual image (it's encrypted, not yet decoded on this Mac)
    /// — just a textual hint, plus the caption if the sender wrote
    /// one. Mirrors how iMessage previews "[image]" on attachments
    /// without a caption.
    private func imagePreview(caption: String?) -> String {
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return "[image] \(trimmed)"
        }
        return "[image]"
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
            existing.mentions = text.mentions
            existing.sentAt = text.sentAt
            existing.updatedAt = comment.updatedAt
        } else {
            let cached = CachedMessage(
                id: id,
                kind: .text,
                sender: text.sender,
                body: text.body,
                replyTo: text.replyTo,
                mentions: text.mentions,
                sentAt: text.sentAt,
                createdAt: comment.createdAt,
                updatedAt: comment.updatedAt
            )
            modelContext.insert(cached)
        }
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
    }

    private func pollCursor() -> Date? {
        var descriptor = FetchDescriptor<CachedMessage>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.updatedAt
    }

    // MARK: - Reactions (v2)

    /// Send a reaction to `targetID`. Optimistic: a `.reaction`
    /// `CachedMessage` row appears immediately so the badge can land
    /// on the bubble corner via `matchedGeometryEffect` before the
    /// network round-trip completes. Same `commitPending` swap-in-place
    /// as text sends — the row's negative ID is replaced with the real
    /// GitHub comment ID without changing `persistentModelID`, so
    /// SwiftUI's `ForEach` doesn't see a removal+insertion.
    func sendReaction(targetID: String, emoji: String) async throws {
        guard let invite = currentInvite, let key = roomKey else {
            throw SendError.notStarted
        }
        let now = Date()
        let me = preferences.displayName
        let payload: MessagePayload = .reaction(ReactionMessage(
            sender: me,
            targetID: targetID,
            emoji: emoji,
            sentAt: now
        ))

        let pendingID = -Int.random(in: 1...Int.max)
        let pendingRow = CachedMessage(
            id: pendingID,
            kind: .reaction,
            sender: me,
            body: emoji,
            replyTo: nil,
            sentAt: now,
            createdAt: now,
            updatedAt: now,
            reactionTargetID: targetID
        )
        modelContext.insert(pendingRow)
        try? modelContext.save()

        do {
            let envelope = try crypto.seal(payload, with: key)
            let wire = try envelope.encodeForWire()
            let comment = try await github.postComment(invite: invite, body: wire)
            commitPendingReaction(pendingRow, withRealComment: comment)
        } catch {
            modelContext.delete(pendingRow)
            try? modelContext.save()
            throw error
        }
    }

    /// Revoke a previously-sent reaction. Same optimistic pattern as
    /// `sendReaction` — a `.reactionRemove` row appears immediately
    /// with a fresh `sentAt`, which the render-time aggregator uses to
    /// flip the badge state off in the same render cycle.
    func removeReaction(targetID: String, emoji: String) async throws {
        guard let invite = currentInvite, let key = roomKey else {
            throw SendError.notStarted
        }
        let now = Date()
        let me = preferences.displayName
        let payload: MessagePayload = .reactionRemove(ReactionRemoveMessage(
            sender: me,
            targetID: targetID,
            emoji: emoji,
            sentAt: now
        ))

        let pendingID = -Int.random(in: 1...Int.max)
        let pendingRow = CachedMessage(
            id: pendingID,
            kind: .reactionRemove,
            sender: me,
            body: emoji,
            replyTo: nil,
            sentAt: now,
            createdAt: now,
            updatedAt: now,
            reactionTargetID: targetID
        )
        modelContext.insert(pendingRow)
        try? modelContext.save()

        do {
            let envelope = try crypto.seal(payload, with: key)
            let wire = try envelope.encodeForWire()
            let comment = try await github.postComment(invite: invite, body: wire)
            commitPendingReaction(pendingRow, withRealComment: comment)
        } catch {
            modelContext.delete(pendingRow)
            try? modelContext.save()
            throw error
        }
    }

    /// Promote a pending reaction (or reactionRemove) row to its real
    /// GitHub comment ID in place. Same race handling as text/image:
    /// if the polling loop already inserted a row with the real id,
    /// drop the pending one to avoid a `@Attribute(.unique)` collision.
    private func commitPendingReaction(
        _ pendingRow: CachedMessage,
        withRealComment comment: GitHubClient.IssueComment
    ) {
        let realID = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == realID })
        let duplicate = (try? modelContext.fetch(descriptor))?.first

        if let duplicate, duplicate.persistentModelID != pendingRow.persistentModelID {
            modelContext.delete(pendingRow)
        } else {
            pendingRow.id = realID
            pendingRow.createdAt = comment.createdAt
            pendingRow.updatedAt = comment.updatedAt
        }
        try? modelContext.save()
    }

    private func upsertReaction(
        comment: GitHubClient.IssueComment,
        reaction: ReactionMessage
    ) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .reaction
            existing.sender = reaction.sender
            existing.body = reaction.emoji
            existing.replyTo = nil
            existing.sentAt = reaction.sentAt
            existing.updatedAt = comment.updatedAt
            existing.reactionTargetID = reaction.targetID
        } else {
            let cached = CachedMessage(
                id: id,
                kind: .reaction,
                sender: reaction.sender,
                body: reaction.emoji,
                replyTo: nil,
                sentAt: reaction.sentAt,
                createdAt: comment.createdAt,
                updatedAt: comment.updatedAt,
                reactionTargetID: reaction.targetID
            )
            modelContext.insert(cached)
        }
    }

    private func upsertReactionRemove(
        comment: GitHubClient.IssueComment,
        removal: ReactionRemoveMessage
    ) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .reactionRemove
            existing.sender = removal.sender
            existing.body = removal.emoji
            existing.replyTo = nil
            existing.sentAt = removal.sentAt
            existing.updatedAt = comment.updatedAt
            existing.reactionTargetID = removal.targetID
        } else {
            let cached = CachedMessage(
                id: id,
                kind: .reactionRemove,
                sender: removal.sender,
                body: removal.emoji,
                replyTo: nil,
                sentAt: removal.sentAt,
                createdAt: comment.createdAt,
                updatedAt: comment.updatedAt,
                reactionTargetID: removal.targetID
            )
            modelContext.insert(cached)
        }
    }
}
