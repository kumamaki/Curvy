import Foundation

/// Build-time configuration for *which* issue in `curvy-room` is the
/// chat room. Release builds talk to Issue #1 — the real chat that the
/// four friends read. Debug builds talk to Issue #2 — a dev-only room
/// so iterating locally (`just run`) doesn't pollute production history.
///
/// The split is purely a property of the running binary. It lives in
/// Swift, not in the `Invite` payload, because the invite is a shared
/// artifact among the four friends — whether any given person is
/// running a Debug or Release build is unrelated to what's in the
/// bundle.
///
/// **Prerequisite:** Issue #2 must exist in `kumamaki/curvy-room`
/// before the first Debug build can post or poll. One-time setup:
///
/// ```sh
/// gh api -X POST repos/kumamaki/curvy-room/issues \
///   -f title='Curvy Debug Room' \
///   -f body='Dev-only — Debug builds post here.'
/// ```
///
/// If Debug builds 404 on the first `listComments` or `postComment`
/// call, the issue is missing — create it with the command above.
enum RoomConfig {
    static let issueNumber: Int = {
        #if DEBUG
        return 2
        #else
        return 1
        #endif
    }()
}

