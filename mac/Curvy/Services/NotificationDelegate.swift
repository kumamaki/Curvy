import Foundation
import OSLog
import UserNotifications

/// Handles user interactions with Curvy's local notification banners.
///
/// Two actions are registered:
///   - "Reply"        — `UNTextInputNotificationAction`: inline text field,
///                      lets the user send a message without opening the app.
///   - "Mark as Read" — `UNNotificationAction`: dismisses the banner and
///                      advances the read watermark so the dock badge clears.
///
/// The handlers are wired to `MessageStore` via closures rather than a
/// direct reference, so the delegate can be created and registered before
/// the store is fully started (e.g., very early in the app lifecycle).
@MainActor
final class NotificationDelegate: NSObject {
    private let logger = AppLog.notif

    static let messageCategory = "curvy.message"
    private static let replyActionID = "REPLY"

    var onReply: (@MainActor (_ text: String, _ replyTo: String?) async -> Void)?

    static func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: replyActionID,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message…"
        )
        let category = UNNotificationCategory(
            identifier: messageCategory,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

extension NotificationDelegate: UNUserNotificationCenterDelegate {
    // Belt-and-suspenders: `announceIfNeeded` already suppresses posts
    // when `isFocused()` is true, so this path is rarely hit in practice.
    // Returning [] ensures no banner appears while Curvy is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let commentID = userInfo["commentID"] as? String

        switch response.actionIdentifier {
        case Self.replyActionID:
            guard
                let textResponse = response as? UNTextInputNotificationResponse,
                !textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                completionHandler()
                return
            }
            let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Call before the Task so completionHandler never crosses
            // isolation — Swift 6 strict concurrency can't send it to
            // @MainActor since it's non-Sendable. The system only requires
            // it be called; the timing relative to async work is fine.
            completionHandler()
            Task { @MainActor [weak self] in
                await self?.onReply?(text, commentID)
            }

        default:
            // User tapped the notification body — the system brings the
            // app to the foreground automatically; nothing extra needed.
            completionHandler()
        }
    }
}
