import Foundation
import Observation
import SwiftUI

/// App-level UI navigation state. Owns the active conversation ID
/// (which conversation the detail pane is showing) and the sidebar's
/// column visibility. Lives at the root and gets passed into both the
/// sidebar (writes `activeConversationID`) and the detail (reads it).
@MainActor
@Observable
final class Navigation {
    /// The conversation currently shown in the detail pane. Defaults
    /// to the main room — the same surface Curvy showed before DMs.
    var activeConversationID: String = ConversationID.room

    /// Sidebar visibility, persisted across the session. Collapsed by
    /// default per spec — DMs are an opt-in surface; the main room
    /// remains the canonical view when you launch the app.
    var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
}

