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

    @ObservationIgnored private let defaults: UserDefaults

    var displayName: String {
        didSet {
            defaults.set(displayName, forKey: Self.displayNameKey)
        }
    }

    /// High-water mark of `createdAt` for messages the user has seen.
    /// Anything strictly newer is "unread" for badge + notification
    /// purposes. `nil` on first launch — `MessageStore.start` sets it
    /// to the latest cached message at that point so historical
    /// content doesn't trigger a wave of notifications.
    var lastReadCreatedAt: Date? {
        didSet {
            if let lastReadCreatedAt {
                defaults.set(lastReadCreatedAt, forKey: Self.lastReadCreatedAtKey)
            } else {
                defaults.removeObject(forKey: Self.lastReadCreatedAtKey)
            }
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
    }
}

