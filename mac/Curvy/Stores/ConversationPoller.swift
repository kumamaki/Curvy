import AppKit
import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftData

/// One conversation's polling + send loop. Each instance owns one
/// `curvy-room` issue plus its envelope key — the main room key for
/// the `room` channel, or an ECDH-derived pair key for a DM.
///
/// `MessageStore` is the registry that holds one of these per active
/// conversation, lazily starting/stopping them. Per-conversation
/// isolation gives us (a) adaptive cadence per channel — the focused
/// DM polls fast, idle channels back off — (b) independent backoff so
/// a rate-limited DM doesn't stall the main room, and (c) a clean
/// home for per-conversation cursor state on `CachedConversation`.
///
/// All public methods are `@MainActor`. SwiftData access is on the
/// main actor; AES-GCM decryption runs concurrently via `withTask-
/// Group` inside `pollOnce` and only the resulting writes resume here.
@MainActor
@Observable
final class ConversationPoller {
    enum Status: Equatable {
        case idle
        case polling
        case error(String)
    }

    enum SendError: Error, CustomStringConvertible {
        case notStarted
        var description: String { "ConversationPoller must be started before sending" }
    }

    let conversationID: String
    let issueNumber: Int
    /// Notification policy: the main room posts banners on every new
    /// message; DMs do too (every DM is a 1:1 message, never noise).
    /// Today the flag exists for future per-conversation muting.
    let postsNotifications: Bool

    private(set) var status: Status = .idle
    private(set) var hasOlderMessages: Bool = false
    private(set) var isLoadingOlderMessages: Bool = false
    /// Count of unread, non-self messages in this conversation.
    /// `MessageStore` aggregates across all pollers for the dock badge.
    private(set) var unreadCount: Int = 0

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let github: GitHubClient
    @ObservationIgnored private let crypto: RoomCrypto
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let blobFetcher: BlobFetcher
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let identityRegistry: IdentityRegistry?
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    /// Called whenever this poller's unread count changes so the
    /// owning `MessageStore` can refresh the aggregate dock badge.
    @ObservationIgnored private let onUnreadChanged: @MainActor () -> Void
    @ObservationIgnored private let logger = AppLog.store

    @ObservationIgnored private let historyPerPage = 50

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var invite: Invite
    /// AES-GCM envelope key for this conversation. 256-bit. For the
    /// main room this is `SymmetricKey(data: invite.roomKeyData)`;
    /// for DMs it's the HKDF output of `X25519(myPriv, peerPub)`.
    /// Held as `SymmetricKey` rather than `Data` so the bytes stay
    /// inside CryptoKit's protected representation — the only place
    /// they escape is BlobFetcher's signature, which currently
    /// declares but doesn't use the param.
    @ObservationIgnored private var envelopeKey: SymmetricKey
    @ObservationIgnored private(set) var consecutiveErrors: Int = 0
    @ObservationIgnored private var notifiedCommentIDs: Set<String> = []

    init(conversationID: String,
         issueNumber: Int,
         invite: Invite,
         envelopeKey: SymmetricKey,
         postsNotifications: Bool,
         modelContext: ModelContext,
         github: GitHubClient,
         crypto: RoomCrypto,
         preferences: Preferences,
         blobFetcher: BlobFetcher,
         notifier: Notifier,
         identityRegistry: IdentityRegistry?,
         isFocused: @escaping @MainActor () -> Bool,
         onUnreadChanged: @escaping @MainActor () -> Void) {
        self.conversationID = conversationID
        self.issueNumber = issueNumber
        self.invite = invite
        self.envelopeKey = envelopeKey
        self.postsNotifications = postsNotifications
        self.modelContext = modelContext
        self.github = github
        self.crypto = crypto
        self.preferences = preferences
        self.blobFetcher = blobFetcher
        self.notifier = notifier
        self.identityRegistry = identityRegistry
        self.isFocused = isFocused
        self.onUnreadChanged = onUnreadChanged
    }

    // MARK: - Lifecycle

    func start(beginPolling: Bool = true) {
        consecutiveErrors = 0
        pollTask?.cancel()

        // First-ever launch in this conversation: baseline the read
        // watermark so existing history doesn't trigger banners.
        let conv = self.conversationRow()
        if conv.lastReadCreatedAt == nil {
            conv.lastReadCreatedAt = latestCreatedAt() ?? Date()
        }
        // Reset page cursor if the cache was wiped under us.
        if conv.oldestPageFetched > 0 && latestCreatedAt() == nil {
            conv.oldestPageFetched = 0
        }
        hasOlderMessages = conv.oldestPageFetched > 1
        modelContext.savePub("poller.start")
        refreshUnread()

        if beginPolling {
            pollTask = Task { [weak self] in
                await self?.seedInitialHistoryIfNeeded()
                await self?.runPollLoop()
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.kickPoll() }
            }
        }
    }

    func kickPoll() {
        consecutiveErrors = 0
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        pollTask?.cancel()
        pollTask = nil
        consecutiveErrors = 0
        status = .idle
        unreadCount = 0
        hasOlderMessages = false
        isLoadingOlderMessages = false
        notifiedCommentIDs.removeAll()
    }

    /// Update the cached invite + key after a rotation (new PAT,
    /// rekey) without tearing the poller down. Caller is responsible
    /// for kicking a poll afterward if needed.
    func updateCredentials(invite: Invite, envelopeKey: SymmetricKey) {
        self.invite = invite
        self.envelopeKey = envelopeKey
    }

    // MARK: - Read state

    func markRead() {
        let conv = self.conversationRow()
        if let latest = latestCreatedAt() {
            conv.lastReadCreatedAt = latest
        }
        notifiedCommentIDs.removeAll()
        modelContext.savePub("poller.markRead")
        refreshUnread()
    }

    private func refreshUnread() {
        let me = preferences.displayName
        let convID = conversationID
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate {
                $0.conversationID == convID &&
                ($0.kindRaw == "text" || $0.kindRaw == "image") &&
                $0.sender != me
            }
        )
        let candidates = (try? modelContext.fetch(descriptor)) ?? []
        let watermark = conversationRow().lastReadCreatedAt
        let count = watermark == nil
            ? candidates.count
            : candidates.filter { $0.createdAt > watermark! }.count
        if unreadCount != count {
            unreadCount = count
            onUnreadChanged()
        }
    }

    private func latestCreatedAt() -> Date? {
        let convID = conversationID
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.conversationID == convID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.createdAt
    }

    private func currentKnownSenders() -> [String] {
        let convID = conversationID
        let descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.conversationID == convID }
        )
        let messages = (try? modelContext.fetch(descriptor)) ?? []
        var set = Set(messages.map(\.sender))
        set.insert(preferences.displayName)
        set.remove("")
        return Array(set)
    }

    // MARK: - Send (text)

    func send(text: String, replyTo: String? = nil) async throws {
        let pending = try insertPendingText(text: text, replyTo: replyTo)
        try await uploadPendingText(pending, text: text, replyTo: replyTo)
    }

    func insertPendingText(text: String, replyTo: String?) throws -> CachedMessage {
        let now = Date()
        let matches = MentionResolver.resolve(
            in: text,
            against: currentKnownSenders()
        )
        let mentions: [String]? = matches.isEmpty ? nil : matches.map(\.name)
        let pendingID = -Int.random(in: 1...Int.max)
        let pendingRow = CachedMessage(
            id: pendingID,
            kind: .pending,
            conversationID: conversationID,
            sender: preferences.displayName,
            body: text,
            replyTo: replyTo,
            mentions: mentions,
            sentAt: now,
            createdAt: now,
            updatedAt: now
        )
        modelContext.insert(pendingRow)
        modelContext.savePub("insertPendingText")
        return pendingRow
    }

    func uploadPendingText(_ pendingRow: CachedMessage, text: String, replyTo: String?) async throws {
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
            sentAt: pendingRow.sentAt
        ))
        do {
            let envelope = try crypto.seal(payload, with: envelopeKey)
            let wire = try envelope.encodeForWire()
            let comment = try await github.postComment(invite: invite, issueNumber: issueNumber, body: wire)
            commitPending(pendingRow, withRealComment: comment)
        } catch {
            modelContext.delete(pendingRow)
            modelContext.savePub("uploadPendingText-failed")
            throw error
        }
    }

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
        modelContext.savePub("commitPendingText")
    }

    // MARK: - Send (image)

    func sendImage(
        prepared: ImagePipeline.Prepared,
        caption: String?,
        replyTo: String? = nil
    ) async throws {
        let now = Date()
        let captionForBody = (caption?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

        let perFileKey = SymmetricKey(size: .bits256)
        let perFileNonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(prepared.bytes, using: perFileKey, nonce: perFileNonce)
        let ciphertext = sealed.ciphertext + sealed.tag

        let perFileKeyData = perFileKey.withUnsafeBytes { Data($0) }
        let keyB64 = perFileKeyData.base64EncodedString()
        let nonceB64 = Data(perFileNonce).base64EncodedString()

        let pendingID = -Int.random(in: 1...Int.max)
        let pendingFilename = "pending-\(abs(pendingID)).jpg"
        let pendingCacheURL: URL
        do {
            pendingCacheURL = try BlobFetcher.stashPending(filename: pendingFilename, data: prepared.bytes)
        } catch {
            logger.warning("couldn't stash pending image: \(error.localizedDescription, privacy: .public)")
            pendingCacheURL = BlobFetcher.cacheDirectory.appending(path: pendingFilename, directoryHint: .notDirectory)
        }

        let assetPath = "blobs/\(UUID().uuidString.lowercased()).bin"
        let pendingRow = CachedMessage(
            id: pendingID,
            kind: .pendingImage,
            conversationID: conversationID,
            sender: preferences.displayName,
            body: captionForBody ?? "",
            replyTo: replyTo,
            sentAt: now,
            createdAt: now,
            updatedAt: now,
            assetPath: assetPath,
            assetSha: nil,
            imageMime: prepared.mime,
            imageWidth: prepared.width,
            imageHeight: prepared.height,
            imageKeyB64: keyB64,
            imageNonceB64: nonceB64,
            imageCachedAt: Date()
        )
        modelContext.insert(pendingRow)
        modelContext.savePub("insertPendingImage")

        var assetSha: String?
        do {
            let ref = try await github.putContent(
                invite: invite,
                path: assetPath,
                bytes: ciphertext
            )
            assetSha = ref.sha

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
                let envelope = try crypto.seal(payload, with: envelopeKey)
                let wire = try envelope.encodeForWire()
                let comment = try await github.postComment(invite: invite, issueNumber: issueNumber, body: wire)
                commitPendingImage(
                    pendingRow,
                    withRealComment: comment,
                    pendingCacheURL: pendingCacheURL,
                    assetPath: ref.path,
                    assetSha: ref.sha
                )
            } catch {
                logger.error("comment post failed after PUT, GC'ing <\(ref.path, privacy: .public)>: \(String(describing: error), privacy: .public)")
                if let sha = assetSha {
                    try? await github.deleteContent(invite: invite, path: ref.path, sha: sha)
                }
                throw error
            }
        } catch {
            logger.error("sendImage failed at <\(assetPath, privacy: .public)>: \(String(describing: error), privacy: .public)")
            modelContext.delete(pendingRow)
            modelContext.savePub("sendImage-failed")
            try? FileManager.default.removeItem(at: pendingCacheURL)
            throw error
        }
    }

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
        modelContext.savePub("commitPendingImage")
    }

    // MARK: - Reactions

    func sendReaction(targetID: String, emoji: String) async throws {
        let now = Date()
        let me = preferences.displayName
        let payload: MessagePayload = .reaction(ReactionMessage(
            sender: me, targetID: targetID, emoji: emoji, sentAt: now
        ))
        let pendingID = -Int.random(in: 1...Int.max)
        let pendingRow = CachedMessage(
            id: pendingID, kind: .reaction, conversationID: conversationID,
            sender: me, body: emoji, replyTo: nil,
            sentAt: now, createdAt: now, updatedAt: now,
            reactionTargetID: targetID
        )
        modelContext.insert(pendingRow)
        modelContext.savePub("insertPendingReaction")
        do {
            let envelope = try crypto.seal(payload, with: envelopeKey)
            let wire = try envelope.encodeForWire()
            let comment = try await github.postComment(invite: invite, issueNumber: issueNumber, body: wire)
            commitPendingReaction(pendingRow, withRealComment: comment)
        } catch {
            modelContext.delete(pendingRow)
            modelContext.savePub("sendReaction-failed")
            throw error
        }
    }

    func removeReaction(targetID: String, emoji: String) async throws {
        let now = Date()
        let me = preferences.displayName
        let payload: MessagePayload = .reactionRemove(ReactionRemoveMessage(
            sender: me, targetID: targetID, emoji: emoji, sentAt: now
        ))
        let pendingID = -Int.random(in: 1...Int.max)
        let pendingRow = CachedMessage(
            id: pendingID, kind: .reactionRemove, conversationID: conversationID,
            sender: me, body: emoji, replyTo: nil,
            sentAt: now, createdAt: now, updatedAt: now,
            reactionTargetID: targetID
        )
        modelContext.insert(pendingRow)
        modelContext.savePub("insertPendingReactionRemove")
        do {
            let envelope = try crypto.seal(payload, with: envelopeKey)
            let wire = try envelope.encodeForWire()
            let comment = try await github.postComment(invite: invite, issueNumber: issueNumber, body: wire)
            commitPendingReaction(pendingRow, withRealComment: comment)
        } catch {
            modelContext.delete(pendingRow)
            modelContext.savePub("removeReaction-failed")
            throw error
        }
    }

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
        modelContext.savePub("commitPendingReaction")
    }

    // MARK: - Identity broadcast (main room only)

    /// Seal and post an `.identity` envelope. Only the main-room
    /// poller calls this — DM channels don't carry identity announces.
    func postIdentity(_ announce: IdentityAnnounce) async throws {
        let payload: MessagePayload = .identity(announce)
        let envelope = try crypto.seal(payload, with: envelopeKey)
        let wire = try envelope.encodeForWire()
        _ = try await github.postComment(invite: invite, issueNumber: issueNumber, body: wire)
    }

    // MARK: - Polling

    func pollOnce() async {
        do {
            let since = pollCursor()
            let comments = try await github.listComments(
                invite: invite,
                issueNumber: issueNumber,
                since: since
            )
            await decryptAndIngest(comments)
            consecutiveErrors = 0
            if status != .polling { status = .polling }
        } catch {
            consecutiveErrors += 1
            status = .error("\(error)")
        }
    }

    private func seedInitialHistoryIfNeeded() async {
        let conv = self.conversationRow()
        guard conv.oldestPageFetched == 0 else { return }
        do {
            let info = try await github.issueInfo(invite: invite, issueNumber: issueNumber)
            guard info.comments > 0 else {
                conv.oldestPageFetched = 1
                hasOlderMessages = false
                modelContext.savePub("seed-empty")
                return
            }
            let lastPage = max(1, Int(ceil(Double(info.comments) / Double(historyPerPage))))
            let comments = try await github.listComments(
                invite: invite,
                issueNumber: issueNumber,
                page: lastPage,
                perPage: historyPerPage
            )
            await decryptAndIngest(comments)
            conv.oldestPageFetched = lastPage
            hasOlderMessages = lastPage > 1
            modelContext.savePub("seed")
        } catch {
            logger.warning("history seed failed (\(self.conversationID, privacy: .public)): \(String(describing: error), privacy: .public)")
            conv.oldestPageFetched = 1
            hasOlderMessages = false
            modelContext.savePub("seed-failed")
        }
    }

    func loadOlderMessages() async {
        let conv = self.conversationRow()
        guard !isLoadingOlderMessages, conv.oldestPageFetched > 1 else { return }
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }
        let targetPage = conv.oldestPageFetched - 1
        do {
            let comments = try await github.listComments(
                invite: invite,
                issueNumber: issueNumber,
                page: targetPage,
                perPage: historyPerPage
            )
            await decryptAndIngest(comments)
            conv.oldestPageFetched = targetPage
            hasOlderMessages = targetPage > 1
            modelContext.savePub("loadOlder")
        } catch {
            logger.warning("loadOlder page <\(targetPage, privacy: .public)> failed (\(self.conversationID, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    private func decryptAndIngest(_ comments: [GitHubClient.IssueComment]) async {
        let localCrypto = crypto
        let key = envelopeKey
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
            ingestDecrypted(comment: comment, payload: payload)
        }
        for comment in comments where !decryptedIDs.contains(comment.id) {
            logger.warning("dropped comment <\(comment.id, privacy: .public)> in \(self.conversationID, privacy: .public): decryption failed")
            upsertWeird(comment: comment, error: DecryptError.failed)
        }
        modelContext.savePub("decryptAndIngest")
    }

    private enum DecryptError: Error { case failed }

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

    private func ingestDecrypted(comment: GitHubClient.IssueComment, payload: MessagePayload) {
        switch payload {
        case .text(let text):
            upsertText(comment: comment, text: text)
            announceIfNeeded(
                commentID: comment.id, createdAt: comment.createdAt,
                sender: text.sender, preview: text.body, mentions: text.mentions
            )
        case .image(let image):
            upsertImage(comment: comment, image: image)
            announceIfNeeded(
                commentID: comment.id, createdAt: comment.createdAt,
                sender: image.sender, preview: imagePreview(caption: image.caption)
            )
        case .reaction(let reaction):
            upsertReaction(comment: comment, reaction: reaction)
        case .reactionRemove(let removal):
            upsertReactionRemove(comment: comment, removal: removal)
        case .identity(let announce):
            identityRegistry?.ingest(announce)
        }
    }

    private func announceIfNeeded(
        commentID: Int, createdAt: Date,
        sender: String, preview: String,
        mentions: [String]? = nil
    ) {
        guard postsNotifications else { refreshUnread(); return }
        if sender == preferences.displayName { return }
        let conv = self.conversationRow()
        if let watermark = conv.lastReadCreatedAt, createdAt <= watermark { return }
        if isFocused() {
            let watermark = conv.lastReadCreatedAt ?? .distantPast
            conv.lastReadCreatedAt = max(watermark, createdAt)
            modelContext.savePub("focusedAdvance")
        } else {
            let idKey = String(commentID)
            guard !notifiedCommentIDs.contains(idKey) else {
                refreshUnread()
                return
            }
            let me = preferences.displayName
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

    private func imagePreview(caption: String?) -> String {
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return "[image] \(trimmed)"
        }
        return "[image]"
    }

    private func upsertText(comment: GitHubClient.IssueComment, text: TextMessage) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            guard existing.updatedAt != comment.updatedAt else { return }
            existing.kind = .text
            existing.conversationID = conversationID
            existing.sender = text.sender
            existing.body = text.body
            existing.replyTo = text.replyTo
            existing.mentions = text.mentions
            existing.sentAt = text.sentAt
            existing.updatedAt = comment.updatedAt
        } else {
            modelContext.insert(CachedMessage(
                id: id, kind: .text,
                conversationID: conversationID,
                sender: text.sender, body: text.body, replyTo: text.replyTo,
                mentions: text.mentions, sentAt: text.sentAt,
                createdAt: comment.createdAt, updatedAt: comment.updatedAt
            ))
        }
    }

    private func upsertImage(comment: GitHubClient.IssueComment, image: ImageMessage) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        let row: CachedMessage
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            if existing.updatedAt == comment.updatedAt {
                blobFetcher.materialize(existing, invite: invite, roomKey: envelopeKey.withUnsafeBytes { Data($0) })
                return
            }
            existing.kind = .image
            existing.conversationID = conversationID
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
                id: id, kind: .image,
                conversationID: conversationID,
                sender: image.sender, body: image.caption ?? "",
                replyTo: image.replyTo, sentAt: image.sentAt,
                createdAt: comment.createdAt, updatedAt: comment.updatedAt,
                assetPath: image.assetPath, assetSha: image.assetSha,
                imageMime: image.mime, imageWidth: image.width, imageHeight: image.height,
                imageKeyB64: image.keyB64, imageNonceB64: image.nonceB64,
                imageCachedAt: nil
            )
            modelContext.insert(cached)
            row = cached
        }
        blobFetcher.materialize(row, invite: invite, roomKey: envelopeKey.withUnsafeBytes { Data($0) })
    }

    private func upsertReaction(comment: GitHubClient.IssueComment, reaction: ReactionMessage) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .reaction
            existing.conversationID = conversationID
            existing.sender = reaction.sender
            existing.body = reaction.emoji
            existing.replyTo = nil
            existing.sentAt = reaction.sentAt
            existing.updatedAt = comment.updatedAt
            existing.reactionTargetID = reaction.targetID
        } else {
            modelContext.insert(CachedMessage(
                id: id, kind: .reaction,
                conversationID: conversationID,
                sender: reaction.sender, body: reaction.emoji, replyTo: nil,
                sentAt: reaction.sentAt,
                createdAt: comment.createdAt, updatedAt: comment.updatedAt,
                reactionTargetID: reaction.targetID
            ))
        }
    }

    private func upsertReactionRemove(comment: GitHubClient.IssueComment, removal: ReactionRemoveMessage) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .reactionRemove
            existing.conversationID = conversationID
            existing.sender = removal.sender
            existing.body = removal.emoji
            existing.replyTo = nil
            existing.sentAt = removal.sentAt
            existing.updatedAt = comment.updatedAt
            existing.reactionTargetID = removal.targetID
        } else {
            modelContext.insert(CachedMessage(
                id: id, kind: .reactionRemove,
                conversationID: conversationID,
                sender: removal.sender, body: removal.emoji, replyTo: nil,
                sentAt: removal.sentAt,
                createdAt: comment.createdAt, updatedAt: comment.updatedAt,
                reactionTargetID: removal.targetID
            ))
        }
    }

    private func upsertWeird(comment: GitHubClient.IssueComment, error: any Error) {
        let id = comment.id
        let descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.kind = .weird
            existing.conversationID = conversationID
            existing.body = "\(error)"
            existing.updatedAt = comment.updatedAt
        } else {
            modelContext.insert(CachedMessage(
                id: id, kind: .weird,
                conversationID: conversationID,
                sender: "", body: "\(error)", replyTo: nil,
                sentAt: comment.createdAt,
                createdAt: comment.createdAt, updatedAt: comment.updatedAt
            ))
        }
    }

    private func pollCursor() -> Date? {
        let convID = conversationID
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.conversationID == convID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.updatedAt
    }

    // MARK: - CachedConversation lookup

    /// Fetch (or create on-the-fly) the `CachedConversation` row for
    /// this poller's `conversationID`. The row should normally already
    /// exist — `MessageStore` creates it when spinning this poller up
    /// — but we self-heal in case the cache was wiped under us.
    private func conversationRow() -> CachedConversation {
        let convID = conversationID
        let descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate { $0.conversationID == convID }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            return existing
        }
        let row = CachedConversation(
            conversationID: conversationID,
            issueNumber: issueNumber,
            kind: conversationID == ConversationID.room ? .room : .dm
        )
        modelContext.insert(row)
        modelContext.savePub("conversationRow.heal")
        return row
    }
}

