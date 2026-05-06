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

    @ObservationIgnored private let defaults: UserDefaults

    var displayName: String {
        didSet {
            defaults.set(displayName, forKey: Self.displayNameKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.displayNameKey), !stored.isEmpty {
            self.displayName = stored
        } else {
            self.displayName = NSFullUserName()
        }
    }
}

