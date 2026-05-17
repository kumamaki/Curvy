import Foundation
import SwiftData

/// Resolves the GitHub issue number that holds the DM channel between
/// this device and a peer. Either reuses an existing pair issue
/// (found by deterministic title scan) or creates one on first
/// contact. Results are persisted to `CachedConversation` so the
/// resolver short-circuits after the first round-trip per peer.
///
/// Both endpoints converge on the same `conversationID` and the same
/// issue title because both are computed from the sorted pair of
/// userIDs (see `ConversationID.dm` / `ConversationID.dmIssueTitle`)
/// — no coordination required.
@MainActor
struct DMResolver {
    let github: GitHubClient
    let modelContext: ModelContext

    init(github: GitHubClient, modelContext: ModelContext) {
        self.github = github
        self.modelContext = modelContext
    }

    /// Return the issue number for `conversationID`. If a
    /// `CachedConversation` row exists, returns its `issueNumber`
    /// without a round-trip. Otherwise scans the repo's issue list
    /// for the deterministic title, and creates the issue if missing.
    /// Caller is responsible for materialising the `CachedConversation`
    /// row after this returns (so an explicit creation path can also
    /// store `peerUserID`).
    func resolveIssueNumber(
        invite: Invite,
        conversationID: String,
        myUserID: UUID,
        peerUserID: UUID
    ) async throws -> Int {
        if let cached = lookupCached(conversationID: conversationID) {
            return cached
        }
        let title = ConversationID.dmIssueTitle(myUserID, peerUserID)
        let existing = try await github.listIssues(invite: invite)
        if let hit = existing.first(where: { $0.title == title }) {
            return hit.number
        }
        let created = try await github.createIssue(
            invite: invite,
            title: title,
            body: "Curvy DM — do not edit. Comments are AES-GCM ciphertext under a per-pair X25519 key."
        )
        return created.number
    }

    private func lookupCached(conversationID id: String) -> Int? {
        let descriptor = FetchDescriptor<CachedConversation>(
            predicate: #Predicate { $0.conversationID == id }
        )
        return (try? modelContext.fetch(descriptor))?.first?.issueNumber
    }
}

