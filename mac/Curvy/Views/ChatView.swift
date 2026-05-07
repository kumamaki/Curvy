import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \CachedMessage.createdAt) private var messages: [CachedMessage]

    @State private var draftText: String = ""
    @State private var imageDraft: ImagePipeline.Prepared?
    @State private var replyingTo: CachedMessage?
    // Initialized to `.bottom` so the very first layout pass asks
    // the ScrollView to anchor at the end — equivalent intent to
    // `.defaultScrollAnchor(.bottom)` but routed through the
    // imperative `ScrollPosition` API, which (per Apple's own forum
    // guidance) is the only reliable path with `LazyVStack`. The
    // declarative `defaultScrollAnchor` is known to leave a blank
    // viewport with lazy content until the user scrolls.
    @State private var scrollPosition = ScrollPosition(idType: PersistentIdentifier.self, edge: .bottom)
    @State private var isPinnedToBottom: Bool = true
    @State private var didInitialScroll: Bool = false
    @State private var shakeTrigger: Int = 0
    @State private var isDropTargeted: Bool = false

    /// Shared namespace for the reaction "stick" animation. Picker
    /// emojis publish a matched-geometry source keyed by
    /// `(targetID, emoji)`; the badge that lands on the bubble corner
    /// publishes the matching destination. SwiftUI animates the emoji
    /// between them — same motion iMessage uses on tapback landing.
    @Namespace private var reactionNamespace

    private let pipeline = ImagePipeline()

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MessageComposer(
                    draftText: $draftText,
                    imageDraft: $imageDraft,
                    replyingTo: $replyingTo,
                    shakeTrigger: shakeTrigger,
                    knownSenders: knownSenders,
                    onSend: send,
                    onPickError: { _ in shakeTrigger += 1 },
                    onLoadURL: preparePicked(url:),
                    onLoadProviders: handleProviders(_:)
                )
            }
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                handleProviders(providers)
                return true
            }
            .overlay {
                if isDropTargeted {
                    dropZoneOverlay
                }
            }
            .background(DisableTextFieldDrops())
            .animation(
                reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.18),
                value: isDropTargeted
            )
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
            // The initial mark-read + auth prompt fire once when the
            // chat first becomes visible. `.task` is one-shot per view
            // identity, which is exactly what we want — re-onboarding
            // remounts ChatView so both re-run (markRead is cheap;
            // auth is a no-op once the user has answered).
            //
            // markRead first so the dock badge clears immediately on
            // app open regardless of how long the user takes to
            // dismiss the auth dialog.
            .task {
                store.markRead()
                _ = await Notifier.live.requestAuthorization()
            }
            // Window regaining focus is the canonical "user is reading
            // again" signal. Bumps the watermark, clears the badge,
            // dismisses any banners still sitting in Notification
            // Center.
            .onChange(of: scenePhase) { _, new in
                if new == .active {
                    store.markRead()
                }
            }
    }

    /// Window-spanning drop affordance. Shown when the user is
    /// dragging an image anywhere over the chat. The dashed inset
    /// echoes Mail.app's "drop to attach" visual; the frosted backdrop
    /// dims the message list so the user knows the drop is the
    /// dominant interaction right now. `.allowsHitTesting(false)` is
    /// critical — without it, the overlay's NSView would steal the
    /// drop from the parent's `.onDrop`.
    private var dropZoneOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 16) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.primary)

                VStack(spacing: 4) {
                    Text("Drop to attach")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Encrypted before it leaves your Mac")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
                .padding(14)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
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

    /// Pre-compute one row spec per non-reaction message before the
    /// `ForEach` runs. Reaction rows get folded out of the bubble list
    /// here and reattached as a `MessageReactions` aggregate on the
    /// row their `reactionTargetID` points at.
    ///
    /// Keying RowItem by `persistentModelID` (rather than the GitHub
    /// `id`) keeps view identity stable when `MessageStore.send`
    /// updates a pending row's `id` in place — no view re-creation,
    /// no flicker.
    /// Distinct sender names across the live message list, plus the
    /// local user. Used as the input set for the body-text mention
    /// resolver — both for receiver-side highlight (here) and as a
    /// snapshot the composer reads to filter the autocomplete picker.
    /// Reading `messages` registers the SwiftData dependency, so any
    /// new sender lights up as soon as their first message lands in
    /// the cache.
    private var knownSenders: [String] {
        var set = Set(messages.map(\.sender))
        set.insert(store.displayName)
        set.remove("")
        return set.sorted()
    }

    private var rows: [RowItem] {
        let myName = store.displayName
        let senders = knownSenders
        // Handle map is the same for every row in this snapshot, so
        // we derive it once and lift the per-row work to a dictionary
        // lookup. Authoritative `msg.mentions` (full names from the
        // wire) gets paired with handles via this same map so the
        // renderer can highlight whichever form was typed.
        let handleMap = MentionResolver.handles(for: senders)

        var bubbleMessages: [CachedMessage] = []
        var reactionRows: [CachedMessage] = []
        for msg in messages {
            switch msg.kind {
            case .reaction, .reactionRemove:
                reactionRows.append(msg)
            default:
                bubbleMessages.append(msg)
            }
        }

        let aggregated = aggregateReactions(rows: reactionRows)
        let byID = Dictionary(uniqueKeysWithValues: bubbleMessages.map { ($0.id, $0) })

        var prev: CachedMessage?
        return bubbleMessages.map { msg in
            defer { prev = msg }
            let isNewGroup = prev?.sender != msg.sender || prev?.kind != msg.kind
            let replyParent = msg.replyTo
                .flatMap { Int($0) }
                .flatMap { byID[$0] }
            let targetKey = String(msg.id)
            // Authoritative when `msg.mentions` is non-nil (sender
            // resolved them at send time). Fallback rescans the body
            // against this client's known senders — covers messages
            // sent before the receiver had observed the mentioned
            // person, and any client where the sender's cache was
            // empty when they typed `@Name`.
            let resolved: [MentionMatch] = msg.mentions.map { names in
                names.map { name in
                    MentionMatch(name: name, handle: handleMap[name] ?? name)
                }
            } ?? MentionResolver.resolve(in: msg.body, against: senders)
            return RowItem(
                message: msg,
                isMine: msg.kind != .weird && msg.sender == myName,
                isNewGroup: isNewGroup,
                replyTarget: replyParent,
                reactions: aggregated[targetKey] ?? .empty(targetID: targetKey),
                mentionResolutions: resolved
            )
        }
    }

    /// Fold raw `.reaction` / `.reactionRemove` rows into per-target
    /// `MessageReactions` aggregates. A reaction is "live" iff no
    /// matching `.reactionRemove` (same sender + same emoji + same
    /// target) carries a strictly-newer `sentAt`. Per (sender, emoji),
    /// only the most recent live reaction counts — a sender who
    /// reacted, removed, then re-reacted shows up once.
    private func aggregateReactions(rows: [CachedMessage]) -> [String: MessageReactions] {
        var reactionsByTarget: [String: [CachedMessage]] = [:]
        var removesByTarget: [String: [CachedMessage]] = [:]
        for r in rows {
            guard let tid = r.reactionTargetID else { continue }
            if r.kind == .reaction {
                reactionsByTarget[tid, default: []].append(r)
            } else {
                removesByTarget[tid, default: []].append(r)
            }
        }

        var aggregated: [String: MessageReactions] = [:]
        for (tid, reactions) in reactionsByTarget {
            let removes = removesByTarget[tid] ?? []
            // (sender|emoji) -> latest live reaction
            var liveBySig: [String: CachedMessage] = [:]
            for r in reactions {
                let killed = removes.contains { rm in
                    rm.sender == r.sender && rm.body == r.body && rm.sentAt > r.sentAt
                }
                if killed { continue }
                let sig = "\(r.sender)|\(r.body)"
                if let existing = liveBySig[sig], existing.sentAt > r.sentAt { continue }
                liveBySig[sig] = r
            }

            var byEmoji: [String: [CachedMessage]] = [:]
            for r in liveBySig.values {
                byEmoji[r.body, default: []].append(r)
            }

            let groups = byEmoji.map { (emoji, members) -> ReactionGroup in
                let sorted = members.sorted { $0.sentAt < $1.sentAt }
                return ReactionGroup(
                    emoji: emoji,
                    senders: sorted.map(\.sender),
                    earliestSentAt: sorted.first?.sentAt ?? .distantPast
                )
            }
            .sorted { $0.earliestSentAt < $1.earliestSentAt }

            aggregated[tid] = MessageReactions(targetID: tid, groups: groups)
        }
        return aggregated
    }

    /// Resolve a tapback action: send if `alreadyMine` is false, remove
    /// if true. Errors shake the composer rather than throwing —
    /// reactions are background-noise interactions, not first-class
    /// sends, so we don't want to disrupt drafts on a failed react.
    private func toggleReaction(targetID: String, emoji: String, alreadyMine: Bool) {
        Task {
            do {
                if alreadyMine {
                    try await store.removeReaction(targetID: targetID, emoji: emoji)
                } else {
                    try await store.sendReaction(targetID: targetID, emoji: emoji)
                }
            } catch {
                shakeTrigger += 1
            }
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
                        reactions: row.reactions,
                        mentionResolutions: row.mentionResolutions,
                        mySender: store.displayName,
                        reactionNamespace: reactionNamespace,
                        onReply: { replyingTo = $0 },
                        onCopy: { copy(row.message) },
                        onToggleReaction: { emoji, alreadyMine in
                            toggleReaction(
                                targetID: String(row.message.id),
                                emoji: emoji,
                                alreadyMine: alreadyMine
                            )
                        }
                    )
                    // `.equatable()` lets SwiftUI skip MessageRow body
                    // re-eval on scroll-driven ChatView body refreshes.
                    // Without this, every visible row re-evaluates per
                    // scroll tick because the closures above are
                    // non-Equatable and defeat the default view diff.
                    .equatable()
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
        .scrollPosition($scrollPosition, anchor: .bottom)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // Single handler for both cold-load seed and new-message
        // auto-follow. Targeting by id (not by edge) is critical with
        // LazyVStack: id-based scroll forces the framework to
        // materialize the target row, edge-based scroll only goes to
        // the bottom of currently-laid-out content (which is the top
        // of the stack on cold load). `initial: true` runs the seed
        // synchronously when the view first sees a non-nil last id.
        .onChange(of: messages.last?.persistentModelID, initial: true) { _, newID in
            guard let newID else { return }
            if !didInitialScroll {
                // Seed runs unconditionally. No animation: we want
                // the very first paint to land at the bottom, not
                // animate from the top.
                scrollPosition.scrollTo(id: newID, anchor: .bottom)
                didInitialScroll = true
                return
            }
            // Subsequent fires are auto-follow: gated so a user in
            // scrollback isn't yanked when a new message arrives.
            guard isPinnedToBottom else { return }
            withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.22)) {
                scrollPosition.scrollTo(id: newID, anchor: .bottom)
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
        let attachedImage = imageDraft

        // Empty composer (no text, no attachment) is a silent no-op
        // — the send button is always tappable per design, but
        // pressing it with nothing to send shouldn't fire a network
        // request.
        guard !trimmed.isEmpty || attachedImage != nil else { return }

        let textToSend = draftText
        let replyID = replyingTo.map { String($0.id) }
        let captionToSend = trimmed.isEmpty ? nil : draftText

        // Snapshot then clear so the UI feels immediate. We restore
        // the snapshot on failure below.
        draftText = ""
        imageDraft = nil
        replyingTo = nil

        Task {
            do {
                if let attachedImage {
                    try await store.sendImage(
                        prepared: attachedImage,
                        caption: captionToSend,
                        replyTo: replyID
                    )
                } else {
                    try await store.send(text: textToSend, replyTo: replyID)
                }
            } catch {
                // Restore drafts so the user doesn't lose their
                // typing or attachment, and shake the composer so the
                // failure is tactilely obvious. The store's `status`
                // reflects the underlying error in the toolbar
                // Live/Offline label.
                draftText = textToSend
                imageDraft = attachedImage
                shakeTrigger += 1
            }
        }
    }

    private func copy(_ message: CachedMessage) {
        guard message.kind == .text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.body, forType: .string)
    }

    // MARK: - Image input handlers

    /// Drag-drop and paste both deliver `[NSItemProvider]`. We pick
    /// the first provider that yields either a file URL or an NSImage
    /// and run it through the pipeline. Lives here (rather than in
    /// `MessageComposer`) so the window-wide `.onDrop` and the
    /// composer's `.onPasteCommand` / file importer all share a
    /// single code path.
    private func handleProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { object, error in
                if error != nil {
                    DispatchQueue.main.async { shakeTrigger += 1 }
                    return
                }
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async { preparePicked(image: image) }
            }
            return
        }

        // Fallback: treat as a file URL. Drag-from-Finder lands here.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if error != nil {
                    DispatchQueue.main.async { shakeTrigger += 1 }
                    return
                }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                } else {
                    url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async { preparePicked(url: url) }
            }
        }
    }

    private func preparePicked(url: URL) {
        do {
            imageDraft = try pipeline.prepare(url: url)
        } catch {
            shakeTrigger += 1
        }
    }

    private func preparePicked(image: NSImage) {
        do {
            imageDraft = try pipeline.prepare(image: image)
        } catch {
            shakeTrigger += 1
        }
    }
}

/// Reaches into the host window and calls `unregisterDraggedTypes()`
/// on every `NSTextField` in the tree. This is the only way to keep
/// the composer's text field from intercepting file drops as text:
/// AppKit dispatches drags deepest-first to any view that's
/// `registeredForDraggedTypes`, and `NSTextField` natively claims
/// `.fileURL` / `.string`. Once unregistered, drag events bubble up
/// to the SwiftUI `.onDrop` modifier on `ChatView`.
///
/// Idempotent — calling `unregisterDraggedTypes()` twice is a no-op.
/// `updateNSView` re-walks on every render so a freshly-mounted
/// composer (e.g. after window restore) gets disabled too.
private struct DisableTextFieldDrops: NSViewRepresentable {
    func makeNSView(context: Context) -> Hook { Hook() }

    func updateNSView(_ nsView: Hook, context: Context) {
        nsView.scheduleSweep()
    }

    final class Hook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleSweep()
        }

        func scheduleSweep() {
            DispatchQueue.main.async { [weak self] in self?.sweep() }
        }

        private func sweep() {
            guard let root = window?.contentView else { return }
            walk(root)
        }

        private func walk(_ view: NSView) {
            if view is NSTextField {
                view.unregisterDraggedTypes()
            }
            for sub in view.subviews { walk(sub) }
        }
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
    let reactions: MessageReactions
    let mentionResolutions: [MentionMatch]
    var id: PersistentIdentifier { message.persistentModelID }
}

