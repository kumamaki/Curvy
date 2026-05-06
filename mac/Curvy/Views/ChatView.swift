import AppKit
import SwiftData
import SwiftUI

/// The room. Top is the window's `.toolbar` (title + status subtitle
/// + sign-out); middle is the scrolling message list with bubbles
/// fed by `@Query`; bottom is the composer attached via
/// `.safeAreaInset` so the message content can scroll under the
/// composer's material edge.
///
/// All polling and sending lives in `MessageStore`. This view reads
/// from the cache, derives `isMine` from the current display name,
/// and posts user input through `store.send`.
struct ChatView: View {
    @Environment(SessionStore.self) private var session
    @Environment(MessageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \CachedMessage.createdAt) private var messages: [CachedMessage]

    @State private var draftText: String = ""
    @State private var replyingTo: CachedMessage?
    @State private var scrollAnchor: PersistentIdentifier?
    @State private var isPinnedToBottom: Bool = true
    @State private var shakeTrigger: Int = 0

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MessageComposer(
                    draftText: $draftText,
                    replyingTo: $replyingTo,
                    shakeTrigger: shakeTrigger,
                    onSend: send
                )
            }
            .navigationTitle("Curvy")
            .navigationSubtitle(statusSubtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        session.signOut()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .help("Sign out")
                }
            }
    }

    /// Title-bar subtitle that doubles as a connection indicator.
    /// Replaces the (redundant for a one-room app) repo slug with a
    /// coloured Live / Offline text — green when the polling loop
    /// is healthy, orange when it's hit an error and is backing off.
    private var statusSubtitle: Text {
        if case .error = store.status {
            return Text("Offline").foregroundStyle(.orange)
        }
        return Text("Live").foregroundStyle(.green)
    }

    /// Pre-compute one row spec per message before the `ForEach` runs.
    /// Keying by `persistentModelID` (rather than the GitHub `id`)
    /// keeps view identity stable when `MessageStore.send` updates a
    /// pending row's `id` in place — no view re-creation, no flicker.
    private var rows: [RowItem] {
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var prev: CachedMessage?
        return messages.map { msg in
            defer { prev = msg }
            let isNewGroup = prev?.sender != msg.sender || prev?.kind != msg.kind
            let replyParent = msg.replyTo
                .flatMap { Int($0) }
                .flatMap { byID[$0] }
            return RowItem(
                message: msg,
                isMine: msg.kind != .weird && msg.sender == store.displayName,
                isNewGroup: isNewGroup,
                replyTarget: replyParent
            )
        }
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    MessageRow(
                        message: row.message,
                        isMine: row.isMine,
                        showSenderLabel: row.isNewGroup,
                        replyTarget: row.replyTarget,
                        onReply: { replyingTo = $0 },
                        onCopy: { copy(row.message) }
                    )
                    .padding(.top, row.isNewGroup ? 12 : 2)
                    .animation(
                        reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.22),
                        value: row.isNewGroup
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .scrollTargetLayout()
            .animation(
                reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.82),
                value: messages.count
            )
        }
        .scrollPosition(id: $scrollAnchor, anchor: .bottom)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onAppear {
            scrollAnchor = messages.last?.persistentModelID
        }
        .onChange(of: messages.last?.persistentModelID) { _, newID in
            // Only auto-scroll when the user is already near the
            // bottom — never yank them out of scrollback to read a
            // new arrival they haven't asked for.
            guard isPinnedToBottom, let newID else { return }
            withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.22)) {
                scrollAnchor = newID
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let bottomOfView = geometry.contentOffset.y + geometry.containerSize.height
            return bottomOfView >= geometry.contentSize.height - 80
        } action: { _, atBottom in
            isPinnedToBottom = atBottom
        }
    }

    private func send() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let textToSend = draftText
        let replyID = replyingTo.map { String($0.id) }
        draftText = ""
        replyingTo = nil
        Task {
            do {
                try await store.send(text: textToSend, replyTo: replyID)
            } catch {
                // Restore the draft so the user doesn't lose their
                // typing, and shake the composer so the failure is
                // tactilely obvious. The store's `status` reflects the
                // underlying error in the toolbar Live/Offline label.
                draftText = textToSend
                shakeTrigger += 1
            }
        }
    }

    private func copy(_ message: CachedMessage) {
        guard message.kind == .text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.body, forType: .string)
    }
}

/// One precomputed row's worth of view-state. Lives outside ForEach
/// so each render walks the messages array once instead of N times.
/// Keyed by `persistentModelID` so an in-place id update on a
/// pending row doesn't change the view's identity.
private struct RowItem: Identifiable {
    let message: CachedMessage
    let isMine: Bool
    let isNewGroup: Bool
    let replyTarget: CachedMessage?
    var id: PersistentIdentifier { message.persistentModelID }
}

