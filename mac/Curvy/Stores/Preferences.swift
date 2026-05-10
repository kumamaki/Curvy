import AppKit
import Foundation
import Observation

/// User-facing preferences. v1 only stores the display name — the
/// `sender` field that gets baked into the encrypted payload when
/// posting a message. Per CLAUDE.md, identity lives inside the
/// ciphertext on purpose, so this value never travels to GitHub
/// unencrypted.
///
/// Default is `NSFullUserName()` ("Mehdi Khaledi" on this Mac), read
/// once on first construction. Until a settings UI ships, friends who
/// want a different name can run:
///
///     defaults write dev.kumamaki.Curvy DisplayName "<name>"
///
/// The `defaults` UserDefaults injection point exists so tests can use
/// an isolated suite and not pollute the real `dev.kumamaki.Curvy`
/// domain.
@MainActor
@Observable
final class Preferences {
    private static let displayNameKey = "DisplayName"
    private static let lastReadCreatedAtKey = "LastReadCreatedAt"
    private static let oldestPageFetchedKey = "OldestPageFetched"

    @ObservationIgnored private let defaults: UserDefaults

    var displayName: String {
        didSet {
            defaults.set(displayName, forKey: Self.displayNameKey)
        }
    }

    /// Read cursor: high-water mark of `createdAt` for messages the user
    /// has seen. Anything strictly newer counts as unread (badge + banner).
    /// Distinct from `MessageStore.pollCursor()`, which is the `since`
    /// parameter passed to GitHub — that one advances when new comments
    /// arrive, this one advances only when the user looks at them.
    /// `nil` on first launch — `MessageStore.start` sets it to the newest
    /// cached message so historical content doesn't fire a wave of banners.
    var lastReadCreatedAt: Date? {
        didSet {
            if let lastReadCreatedAt {
                defaults.set(lastReadCreatedAt, forKey: Self.lastReadCreatedAtKey)
            } else {
                defaults.removeObject(forKey: Self.lastReadCreatedAtKey)
            }
        }
    }

    /// Tracks how far back history has been loaded from GitHub.
    ///   0  = never seeded (first-ever launch)
    ///   1  = page 1 already fetched — fully loaded, nothing older
    ///   N  = oldest page fetched so far; pages 1..(N-1) still exist on GitHub
    ///
    /// Page numbering with `perPage = 50` is stable: new messages always
    /// append to the end, so page 1 is always the oldest 50 messages
    /// regardless of how many arrive later.
    var oldestPageFetched: Int {
        didSet {
            defaults.set(oldestPageFetched, forKey: Self.oldestPageFetchedKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.displayNameKey), !stored.isEmpty {
            self.displayName = stored
        } else {
            self.displayName = NSFullUserName()
        }
        self.lastReadCreatedAt = defaults.object(forKey: Self.lastReadCreatedAtKey) as? Date
        self.oldestPageFetched = defaults.integer(forKey: Self.oldestPageFetchedKey)
    }
}

