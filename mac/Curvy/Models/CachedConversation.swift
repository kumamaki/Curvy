import Foundation
import SwiftData

/// Per-conversation routing record. Pairs a stable, app-side
/// `conversationID` string ("room" or "dm:<minUUID>:<maxUUID>") with
/// the GitHub-side issue number that holds its comment stream.
///
/// The main room row is synthesised on first launch from `RoomConfig.
/// issueNumber`; DM rows are discovered (or lazily created) by title
/// scan against `curvy-room`. Once cached, callers can look up the
/// issue number for a conversation without re-hitting GitHub.
///
/// `peerUserID` is non-nil only for `kind == .dm` and identifies the
/// other participant from this device's perspective — the sidebar
/// uses it to look up the peer's display name in `IdentityRegistry`.
@Model
final class CachedConversation {
    @Attribute(.unique) var conversationID: String
    var issueNumber: Int
    var kindRaw: String
    var peerUserID: UUID?
    var createdAt: Date

    /// Pagination cursor for back-fill: how far back history has been
    /// fetched from GitHub for *this* conversation.
    ///   0 = never seeded
    ///   1 = page 1 already fetched (fully loaded, nothing older)
    ///   N = oldest page fetched so far
    /// Same semantics as the legacy app-wide `Preferences.oldestPage-
    /// Fetched`, but per-conversation so each room/DM tracks its own
    /// history depth.
    var oldestPageFetched: Int = 0

    /// Per-conversation read watermark: high-water mark of `createdAt`
    /// for messages the user has seen in this conversation. Anything
    /// newer counts as unread. `nil` on first ever launch of this
    /// conversation — the poller sets it to the newest cached row so
    /// historical content doesn't fire a wave of banners.
    var lastReadCreatedAt: Date?

    enum Kind: String {
        case room
        case dm
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .room }
        set { kindRaw = newValue.rawValue }
    }

    init(conversationID: String,
         issueNumber: Int,
         kind: Kind,
         peerUserID: UUID? = nil,
         createdAt: Date = Date(),
         oldestPageFetched: Int = 0,
         lastReadCreatedAt: Date? = nil) {
        self.conversationID = conversationID
        self.issueNumber = issueNumber
        self.kindRaw = kind.rawValue
        self.peerUserID = peerUserID
        self.createdAt = createdAt
        self.oldestPageFetched = oldestPageFetched
        self.lastReadCreatedAt = lastReadCreatedAt
    }
}

/// Stable per-conversation ID derivation. The main room is the
/// constant `"room"`; DMs encode the sorted pair of UUIDs so both
/// endpoints compute the same value without coordination.
enum ConversationID {
    static let room = "room"

    static func dm(_ a: UUID, _ b: UUID) -> String {
        let ids = [a.uuidString.lowercased(), b.uuidString.lowercased()].sorted()
        return "dm:\(ids[0]):\(ids[1])"
    }

    /// Canonical DM issue title. Mirrors the conversation ID minus the
    /// "dm:" prefix, with a leading "DM " so it's human-readable when
    /// scrolling the issue list on github.com.
    static func dmIssueTitle(_ a: UUID, _ b: UUID) -> String {
        let ids = [a.uuidString.lowercased(), b.uuidString.lowercased()].sorted()
        return "DM \(ids[0]):\(ids[1])"
    }
}

