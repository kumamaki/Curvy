import Foundation
import Observation
import SwiftData
import os

/// In-memory + SwiftData-backed roster of known Curvy identities.
///
/// Every `.identity` payload pulled from the main room flows through
/// `ingest(_:)`. The registry de-dupes by `userID` and keeps the
/// freshest announcement (compared by `announcedAt` from inside the
/// ciphertext — never by GitHub's `createdAt`, which would let an
/// out-of-order delivery clobber a newer name).
///
/// Persistence lives in `CachedIdentity`; the registry never holds
/// extra in-memory state, so a fresh launch sees the same roster as
/// the last one without waiting on the poll loop.
@MainActor
@Observable
final class IdentityRegistry {
    @ObservationIgnored private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Upsert an identity announce. No-op if the existing row is
    /// already as new or newer (so a re-replay of historical messages
    /// during a from-scratch ingest doesn't undo a rename).
    func ingest(_ announce: IdentityAnnounce) {
        let userID = announce.userID
        let descriptor = FetchDescriptor<CachedIdentity>(
            predicate: #Predicate { $0.userID == userID }
        )
        let existing = (try? modelContext.fetch(descriptor))?.first
        if let existing {
            guard announce.sentAt > existing.announcedAt else { return }
            existing.displayName = announce.displayName
            existing.pubKey = announce.pubKey
            existing.announcedAt = announce.sentAt
        } else {
            modelContext.insert(CachedIdentity(
                userID: announce.userID,
                displayName: announce.displayName,
                pubKey: announce.pubKey,
                announcedAt: announce.sentAt
            ))
        }
        do {
            try modelContext.save()
            AppLog.session.pub("identity registry upsert <\(announce.userID.uuidString)> name=<\(announce.displayName)>")
        } catch {
            AppLog.session.error("identity registry save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Look up a peer by stable user ID. Returns nil if we've never
    /// seen an announce for that ID — caller decides whether to fall
    /// back on the in-ciphertext `sender` display name.
    func lookup(userID: UUID) -> UserIdentity? {
        let descriptor = FetchDescriptor<CachedIdentity>(
            predicate: #Predicate { $0.userID == userID }
        )
        guard let row = (try? modelContext.fetch(descriptor))?.first else {
            return nil
        }
        return UserIdentity(
            userID: row.userID,
            displayName: row.displayName,
            pubKey: row.pubKey,
            announcedAt: row.announcedAt
        )
    }

    /// All known peers, sorted by display name. The sidebar consumes
    /// this — `excluding` filters out the current user so the roster
    /// shows just the other three friends.
    func roster(excluding selfUserID: UUID?) -> [UserIdentity] {
        let descriptor = FetchDescriptor<CachedIdentity>(
            sortBy: [SortDescriptor(\.displayName)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.compactMap { row in
            if row.userID == selfUserID { return nil }
            return UserIdentity(
                userID: row.userID,
                displayName: row.displayName,
                pubKey: row.pubKey,
                announcedAt: row.announcedAt
            )
        }
    }
}

