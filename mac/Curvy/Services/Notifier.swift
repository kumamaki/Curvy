import AppKit
import Foundation
import OSLog
import UserNotifications

/// Local notifications + dock-tile badge. Stateless wrapper around
/// `UNUserNotificationCenter` and `NSApp.dockTile`, shaped like
/// `GitHubClient` (struct + closure-injection) so tests can swap the
/// real OS sinks for `.noop` without standing up a fake notification
/// center.
///
/// Notifications are content-rich on purpose: a 4-person trusted
/// room behaves like iMessage between friends, so showing
/// `<sender>: <body>` is fine. We never log the body or write it
/// outside the OS notification surface.
@MainActor
struct Notifier {
    /// Prompt the user once for `.alert + .sound`. Idempotent — after
    /// the first answer, subsequent calls return the existing
    /// authorization status without prompting again.
    var requestAuthorization: @MainActor () async -> Bool

    /// Schedule a local notification immediately. `id` should be a
    /// stable per-message string (we use `String(comment.id)`) so
    /// retries from the polling loop coalesce into a single banner
    /// instead of stacking duplicates.
    var post: @MainActor (_ id: String, _ title: String, _ body: String) -> Void

    /// Dismiss every Curvy notification still sitting in Notification
    /// Center. Called on `markRead()` so the user-visible state
    /// matches the in-app "everything is read" state.
    var clearDelivered: @MainActor () -> Void

    /// Set the dock-tile badge. Pass `nil` to clear. We cap display
    /// at "99+" upstream, but this primitive accepts any string.
    var setBadge: @MainActor (_ label: String?) -> Void
}

extension Notifier {
    static var live: Notifier {
        let logger = Logger(subsystem: "dev.kumamaki.Curvy", category: "Notifier")
        let center = UNUserNotificationCenter.current()
        return Notifier(
            requestAuthorization: {
                do {
                    return try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    logger.warning("authorization request failed: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            },
            post: { id, title, body in
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
                center.add(request) { error in
                    if let error {
                        logger.warning("notification post failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            },
            clearDelivered: {
                center.removeAllDeliveredNotifications()
            },
            setBadge: { label in
                NSApp.dockTile.badgeLabel = label
            }
        )
    }

    static let noop = Notifier(
        requestAuthorization: { false },
        post: { _, _, _ in },
        clearDelivered: { },
        setBadge: { _ in }
    )
}

