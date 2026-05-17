import AppKit
import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftData

/// Registry of per-conversation pollers + cross-cutting state (display
/// name, aggregate unread, identity broadcast). Each `Conversation-
/// Poller` it owns runs an independent poll loop against one issue on
/// `curvy-room`, encrypts/decrypts under that conversation's key.
///
/// The store does very little itself: it bootstraps the main-room
/// poller, lazily spins up DM pollers via `openDM(with:)`, and proxies
/// a few convenience methods (`send`, `kickPoll`, `stop`) so callers
/// like `NotificationDelegate` that target the main room don't have to
/// reach through the registry. Everything else lives on the poller.
@MainActor
@Observable
final class MessageStore {
    enum SendError: Error, CustomStringConvertible {
        case notStarted
        case noPollerForConversation(String)
        var description: String {
            switch self {
            case .notStarted: "MessageStore must be started before sending"
            case .noPollerForConversation(let id): "no poller for conversation <\(id)>"
            }
        }
    }

    private(set) var pollers: [String: ConversationPoller] = [:]
    /// Aggregate unread count across every active poller. Drives the
    /// dock badge label.
    private(set) var unreadCount: Int = 0

    /// Read-only snapshot of the active display name. Mirrors the
    /// pre-refactor field so views can keep reading from the store.
    var displayName: String { preferences.displayName }

    /// The main-room poller, if started. Convenience for callers that
    /// always want to address the shared 4-person room.
    var roomPoller: ConversationPoller? { pollers[ConversationID.room] }

    @ObservationIgnored let identityRegistry: IdentityRegistry
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let github: GitHubClient
    @ObservationIgnored private let crypto: RoomCrypto
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let blobFetcher: BlobFetcher
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let isFocused: @MainActor () -> Bool
    @ObservationIgnored private let dmResolver: DMResolver
    @ObservationIgnored private let logger = AppLog.store

    @ObservationIgnored private var currentInvite: Invite?
    @ObservationIgnored private var roomKey: Data?
    @ObservationIgnored private var myIdentity: UserIdentity?
    @ObservationIgnored private var myPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    /// In-flight `openDM` tasks keyed by conversationID. Dedupe so two
    /// concurrent callers (e.g. a sidebar tap and a `task(id:)` firing
    /// on the same selection) join the same resolution instead of
    /// racing two issue-create requests.
    @ObservationIgnored private var openDMTasks: [String: Task<ConversationPoller, any Error>] = [:]
    /// Identity-broadcast task spawned by `start(...)`. Tracked so
    /// `stop()` can cancel it instead of letting an in-flight announce
    /// land after the poller is torn down.
    @ObservationIgnored private var identityBroadcastTask: Task<Void, Never>?

    init(modelContext: ModelContext,
         github: GitHubClient = GitHubClient(),
         crypto: RoomCrypto = RoomCrypto(),
         preferences: Preferences = Preferences(),
         blobFetcher: BlobFetcher? = nil,
         notifier: Notifier = .live,
         identityRegistry: IdentityRegistry,
         dmResolver: DMResolver? = nil,
         isFocused: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive }) {
        self.modelContext = modelContext
        self.github = github
        self.crypto = crypto
        self.preferences = preferences
        self.blobFetcher = blobFetcher ?? BlobFetcher(github: github, modelContext: modelContext)
        self.notifier = notifier
        self.identityRegistry = identityRegistry
        self.dmResolver = dmResolver ?? DMResolver(github: github, modelContext: modelContext)
        self.isFocused = isFocused
    }

    // MARK: - Lifecycle

    /// Start the main-room poller and broadcast identity if needed.
    /// Existing DM pollers (from a previous session) are *not* auto-
    /// resumed — they're spun up lazily when the sidebar selects the
    /// DM. Identity-only main-room polling is enough for the roster
    /// to materialize on cold start.
    ///
    /// `myPrivateKey` is held for DM key derivation when `openDM(with:)`
    /// is called later; nil is allowed for tests that don't exercise
    /// DMs.
    func start(invite: Invite,
               identity: UserIdentity? = nil,
               privateKey: Curve25519.KeyAgreement.PrivateKey? = nil,
               beginPolling: Bool = true) {
        guard let key = invite.roomKeyData else {
            logger.error("invite has no decodable room key")
            return
        }
        currentInvite = invite
        roomKey = key
        myIdentity = identity
        myPrivateKey = privateKey

        // Materialize the main-room CachedConversation row before the
        // poller spins up so its conversationRow() lookup hits cache.
        ensureConversationRow(
            id: ConversationID.room,
            issueNumber: RoomConfig.issueNumber,
            kind: .room,
            peerUserID: nil
        )

        let room = makePoller(
            conversationID: ConversationID.room,
            issueNumber: RoomConfig.issueNumber,
            invite: invite,
            envelopeKey: SymmetricKey(data: key)
        )
        pollers[ConversationID.room] = room
        room.start(beginPolling: beginPolling)

        if beginPolling, let identity {
            identityBroadcastTask?.cancel()
            identityBroadcastTask = Task { [weak self] in
                await self?.broadcastIdentityIfNeeded(identity)
            }
        }
    }

    func kickPoll() {
        for poller in pollers.values { poller.kickPoll() }
    }

    /// Tear down every poller and clear cached invite/key material.
    func stop() {
        identityBroadcastTask?.cancel()
        identityBroadcastTask = nil
        // Cancel any DM open-resolution tasks too — they'd otherwise
        // resolve after stop and insert a poller into the cleared
        // registry.
        for task in openDMTasks.values { task.cancel() }
        openDMTasks.removeAll()
        for poller in pollers.values { poller.stop() }
        pollers.removeAll()
        currentInvite = nil
        roomKey = nil
        myIdentity = nil
        myPrivateKey = nil
        unreadCount = 0
        notifier.setBadge(nil)
        notifier.clearDelivered()
    }

    // MARK: - DM orchestration

    /// Look up (or lazily create) the poller for a DM with `peer`.
    /// On first call for a given peer, resolves the GitHub issue via
    /// `DMResolver` (title scan + optional create), derives the per-
    /// pair AES-GCM key, and spins up a fresh poller. Subsequent calls
    /// return the same instance.
    func openDM(with peer: UserIdentity) async throws -> ConversationPoller {
        guard let invite = currentInvite,
              let myIdentity,
              let myPrivateKey else {
            throw SendError.notStarted
        }
        let convID = ConversationID.dm(myIdentity.userID, peer.userID)
        if let existing = pollers[convID] {
            return existing
        }
        // Coalesce concurrent callers onto a single in-flight Task so
        // we never race two `resolveIssueNumber` calls (which would
        // create two issues with the same title on GitHub) or insert
        // two pollers in `pollers[convID]`.
        if let inFlight = openDMTasks[convID] {
            return try await inFlight.value
        }
        let task = Task<ConversationPoller, any Error> { [self] in
            defer { openDMTasks.removeValue(forKey: convID) }
            let peerPubKey = try peer.keyAgreementPublicKey()
            let pairKey = try RoomCrypto.deriveDMKey(
                myPrivateKey: myPrivateKey,
                theirPublicKey: peerPubKey,
                myUserID: myIdentity.userID,
                theirUserID: peer.userID
            )
            let issueNumber = try await dmResolver.resolveIssueNumber(
                invite: invite,
                conversationID: convID,
                myUserID: myIdentity.userID,
                peerUserID: peer.userID
            )
            // Re-check after the awaits — another caller may have lost
            // a race higher in the function but won here.
            if let existing = pollers[convID] {
                return existing
            }
            ensureConversationRow(
                id: convID,
                issueNumber: issueNumber,
                kind: .dm,
                peerUserID: peer.userID
            )
            let poller = makePoller(
                conversationID: convID,
                issueNumber: issueNumber,
                invite: invite,
                envelopeKey: pairKey
            )
            pollers[convID] = poller
            poller.start()
            return poller
        }
        openDMTasks[convID] = task
        return try await task.value
    }

    /// Lookup-only variant of `openDM(with:)` — returns nil if the
    /// poller hasn't been started yet. Used by views to read state
    /// without triggering issue creation.
    func poller(for conversationID: String) -> ConversationPoller? {
        pollers[conversationID]
    }

    /// Resolve the peer's user ID for a DM conversation. Returns nil
    /// for the main room or for conversations we don't have a cached
    /// row for. Used by the title bar and sidebar to look up the
    /// peer's display name via `IdentityRegistry`.
    func peerUserID(for conversationID: String) -> UUID? {
        guard conversationID != ConversationID.room else { return nil }
        let id = conversationID
        let descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate { $0.conversationID == id }
        )
        return (try? modelContext.fetch(descriptor))?.first?.peerUserID
    }

    // MARK: - Identity broadcast

    /// Post an `.identity` envelope to the main room if the registry
    /// doesn't already have us under the current display name.
    private func broadcastIdentityIfNeeded(_ identity: UserIdentity) async {
        guard let room = pollers[ConversationID.room] else { return }
        if let known = identityRegistry.lookup(userID: identity.userID),
           known.displayName == preferences.displayName,
           known.pubKey == identity.pubKey {
            return
        }
        let announce = IdentityAnnounce(
            userID: identity.userID,
            displayName: preferences.displayName,
            pubKey: identity.pubKey,
            sentAt: Date()
        )
        do {
            try await room.postIdentity(announce)
            if Task.isCancelled { return }
            // Re-check that the room poller is still ours — `stop()`
            // mid-await means a later `start()` may have created a new
            // poller for a different invite, and ingesting our stale
            // announce there would be wrong.
            guard pollers[ConversationID.room] === room else { return }
            identityRegistry.ingest(announce)
            AppLog.session.pub("identity broadcast posted")
        } catch is CancellationError {
            // stop() was called mid-flight — do nothing.
        } catch {
            AppLog.session.error("identity broadcast failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Aggregate unread → dock badge

    /// Called by each poller whenever its unread count changes.
    /// Re-sums across every active poller and updates the dock badge.
    fileprivate func refreshAggregateUnread() {
        let total = pollers.values.reduce(0) { $0 + $1.unreadCount }
        unreadCount = total
        notifier.setBadge(badgeLabel(for: total))
    }

    private func badgeLabel(for count: Int) -> String? {
        if count <= 0 { return nil }
        if count > 99 { return "99+" }
        return String(count)
    }

    // MARK: - Convenience facades (main room)

    /// Send a text message to the main room. Convenience wrapper used
    /// by `NotificationDelegate`'s inline reply, where the routing is
    /// always the shared 4-person room.
    func send(text: String, replyTo: String? = nil) async throws {
        guard let room = roomPoller else { throw SendError.notStarted }
        try await room.send(text: text, replyTo: replyTo)
    }

    // MARK: - Helpers

    private func makePoller(
        conversationID: String,
        issueNumber: Int,
        invite: Invite,
        envelopeKey: SymmetricKey
    ) -> ConversationPoller {
        ConversationPoller(
            conversationID: conversationID,
            issueNumber: issueNumber,
            invite: invite,
            envelopeKey: envelopeKey,
            postsNotifications: true,
            modelContext: modelContext,
            github: github,
            crypto: crypto,
            preferences: preferences,
            blobFetcher: blobFetcher,
            notifier: notifier,
            identityRegistry: conversationID == ConversationID.room ? identityRegistry : nil,
            isFocused: isFocused,
            onUnreadChanged: { [weak self] in
                self?.refreshAggregateUnread()
            }
        )
    }

    private func ensureConversationRow(
        id: String,
        issueNumber: Int,
        kind: CachedConversation.Kind,
        peerUserID: UUID?
    ) {
        let descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate { $0.conversationID == id }
        )
        if (try? modelContext.fetch(descriptor))?.first != nil { return }
        // First time seeing this conversation in the cache. For the
        // main room, seed cursors from the legacy app-wide Preferences
        // values so an upgrading client doesn't redo the history seed
        // or re-banner messages it has already seen.
        let oldestPage: Int
        let lastRead: Date?
        if id == ConversationID.room {
            oldestPage = preferences.oldestPageFetched
            lastRead = preferences.lastReadCreatedAt
        } else {
            oldestPage = 0
            lastRead = nil
        }
        modelContext.insert(CachedConversation(
            conversationID: id,
            issueNumber: issueNumber,
            kind: kind,
            peerUserID: peerUserID,
            oldestPageFetched: oldestPage,
            lastReadCreatedAt: lastRead
        ))
        modelContext.savePub("ensureConversationRow")
    }
}

