import os

/// Topic-keyed `Logger` instances for the app. All entries share the
/// `dev.kumamaki.Curvy` subsystem so `log show --predicate
/// 'subsystem == "dev.kumamaki.Curvy"'` picks them up regardless of
/// category. Tail any one category via `just logs <category>`.
///
/// Conventions:
///   • Use `.pub(...)` for free-form debug strings — it marks the whole
///     interpolation `privacy: .public` so paths / IDs / status codes
///     appear in `log show` instead of `<private>`. Safe for repo paths,
///     comment IDs, HTTP status codes, image dimensions, and error
///     descriptions. **Never** pass the room key, PAT, or decrypted
///     message body through `.pub`.
///   • Reserve `.error(...)` for actual failures; `.warning(...)` for
///     degraded-but-recoverable situations; everything else goes through
///     `.pub` which calls `.notice`. `.debug` is filtered out of
///     `log show` by default, which is why we don't use it.
enum AppLog {
    private static let subsystem = "dev.kumamaki.Curvy"

    /// GitHub REST API calls, status codes, errors.
    static let net     = Logger(subsystem: subsystem, category: "Net")
    /// MessageStore poll loop, send, state transitions.
    static let store   = Logger(subsystem: subsystem, category: "Store")
    /// SessionStore: invite decode, phase transitions, access verification.
    static let session = Logger(subsystem: subsystem, category: "Session")
    /// AES-GCM seal/open results.
    static let crypto  = Logger(subsystem: subsystem, category: "Crypto")
    /// BlobFetcher: download, decrypt, cache hits.
    static let blobs   = Logger(subsystem: subsystem, category: "Blobs")
    /// ImagePipeline: resize, recompress, GIF size warnings.
    static let images  = Logger(subsystem: subsystem, category: "Images")
    /// Notifier + NotificationDelegate: badge, post, response.
    static let notif   = Logger(subsystem: subsystem, category: "Notif")
    /// QuickLookManager: staging, preview lifecycle.
    static let ql      = Logger(subsystem: subsystem, category: "QL")
    /// ChatView scroll: position save/restore, anchor decisions.
    static let ui      = Logger(subsystem: subsystem, category: "UI")
}

extension Logger {
    /// Log a `.notice`-level message with the entire interpolation marked
    /// `privacy: .public`. Avoids per-call-site `, privacy: .public`
    /// boilerplate for dev diagnostics. Use the regular `.error`/`.warning`
    /// APIs with explicit privacy annotations for anything production-sensitive.
    func pub(_ message: String) {
        self.notice("\(message, privacy: .public)")
    }
}
