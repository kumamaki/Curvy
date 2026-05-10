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
    @Environment(UpdateMonitor.self) private var updateMonitor
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
    // Flips true on the first geometry tick that confirms the cold-load
    // seed actually landed at the bottom (gap <= 1pt). Until then the
    // message list renders at opacity 0 — the user never sees the
    // documented LazyVStack-blank-viewport flash, never sees the seed's
    // own scrollTo motion, never sees a half-laid-out top-of-stack.
    // After the flip, this also gates the auto-follow handler so it
    // can't fire before the seed itself has run.
    @State private var didSeed: Bool = false
    // One-shot override of `isPinnedToBottom` for the next bubble that
    // arrives. Set by `send()` so my own outgoing message yanks me to
    // the bottom even if I was reading scrollback. Consumed (reset to
    // false) by the auto-follow handler on the very next bubble id
    // change.
    @State private var forceFollowNextBubble: Bool = false
    // Counter for the "↓ N new" pill. Incremented when a new bubble
    // lands while the user is in scrollback. The geometry callback
    // resets it to zero the moment the user returns to the bottom edge.
    @State private var unreadInScrollback: Int = 0
    // Snapshotted on scene leaving `.active`. On resume, if true, we
    // re-snap to the latest message (user was at the bottom and
    // probably wants to catch up). If false, we leave their scroll
    // position alone — they were reading old messages.
    @State private var wasPinnedAtBackground: Bool = true
    // Drives the brief (~1s) flash on a parent message after the user
    // taps a reply chip to jump to it. Each row compares its own id
    // against this and renders a transient highlight overlay when they
    // match.
    @State private var highlightedID: PersistentIdentifier?
    @State private var shakeTrigger: Int = 0
    @State private var isDropTargeted: Bool = false
    @State private var cachedRows: [RowItem] = []
    @State private var cachedKnownSenders: [String] = []
    // Set to true while handleLastBubbleChange is animating a scroll to
    // bottom. Prevents the geometry callback's intermediate ticks from
    // transiently flipping isPinnedToBottom to false mid-animation,
    // which would miscount a concurrent new message as unread.
    @State private var isProgrammaticallyScrolling: Bool = false
    // Set just before triggering `loadOlderMessages()` to the ID of the
    // top-most visible row. After the prepend lands, `onChange` scrolls
    // back to this row so the user's reading position stays stable.
    @State private var needsScrollRestoreID: PersistentIdentifier?

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
                    knownSenders: cachedKnownSenders,
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
            .task {
                store.markRead()
            }
            // Window regaining focus is the canonical "user is reading
            // again" signal. Bumps the watermark, clears the badge,
            // dismisses any banners still sitting in Notification
            // Center.
            .onChange(of: scenePhase) { _, new in
                if new == .active {
                    store.markRead()
                    // Re-snap to the latest only if the user was at
                    // the bottom when they left. id-based scrollTo
                    // (not edge:) so LazyVStack materializes the
                    // target row — same fix as the cold-load seed.
                    // Animations disabled: the user is already
                    // looking at the screen on resume, a sudden
                    // scroll would feel jarring.
                    if wasPinnedAtBackground, let lastID = cachedRows.last?.id {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            scrollPosition.scrollTo(id: lastID, anchor: .bottom)
                        }
                    }
                } else {
                    wasPinnedAtBackground = isPinnedToBottom
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

    private func buildRows() -> [RowItem] {
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
                if store.isLoadingOlderMessages {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                ForEach(cachedRows) { row in
                    MessageRow(
                        message: row.message,
                        isMine: row.isMine,
                        showSenderLabel: row.isNewGroup,
                        replyTarget: row.replyTarget,
                        reactions: row.reactions,
                        mentionResolutions: row.mentionResolutions,
                        mySender: store.displayName,
                        reactionNamespace: reactionNamespace,
                        isHighlighted: highlightedID == row.id,
                        onReply: { replyingTo = $0 },
                        onCopy: { copy(row.message) },
                        onJumpToReplyParent: { parent in jumpToParent(parent) },
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
        // Hide the list until the seed lands. Avoids the documented
        // blank-viewport flash where LazyVStack measures empty until
        // the first `scrollTo(id:)` materializes rows. We're hiding
        // the rendering, not unmounting it — measurement still runs.
        .opacity(didSeed ? 1 : 0)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onChange(of: cachedRows.last?.id, initial: true) { _, newID in
            handleLastBubbleChange(newID)
        }
        .onChange(of: messages.map(\.id), initial: true) { _, _ in
            let anchorID = needsScrollRestoreID
            cachedRows = buildRows()
            cachedKnownSenders = knownSenders
            // After loading older messages, scroll back to where the
            // user was so the newly-prepended rows appear above them.
            if let anchorID, cachedRows.contains(where: { $0.id == anchorID }) {
                needsScrollRestoreID = nil
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    scrollPosition.scrollTo(id: anchorID, anchor: .top)
                }
            }
        }
        .onChange(of: store.displayName) { _, _ in
            cachedRows = buildRows()
            cachedKnownSenders = knownSenders
        }
        .onScrollGeometryChange(for: ScrollEdgeState.self) { geometry in
            scrollEdgeState(geometry)
        } action: { _, snap in
            handleScrollEdgeState(snap)
        }
        .task { await fallbackReveal() }
        .task(id: highlightedID) { await clearHighlightAfterDelay() }
        .overlay(alignment: .bottom) { jumpToLatestOverlay }
        .overlay(alignment: .top) { updateAvailableOverlay }
        .animation(
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.32, dampingFraction: 0.85),
            value: pillVisible
        )
        .animation(
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.3, dampingFraction: 0.78),
            value: updateMonitor.updateAvailable
        )
    }

    /// Whether the jump-to-latest pill should be on screen this tick.
    /// Pulled out as a computed property because driving the pill's
    /// container `.animation` modifier off a multi-clause boolean
    /// expression inline confuses the type-checker on the
    /// already-long modifier chain.
    private var pillVisible: Bool {
        !isPinnedToBottom && unreadInScrollback > 0
    }

    @ViewBuilder
    private var updateAvailableOverlay: some View {
        if updateMonitor.updateAvailable {
            UpdateAvailablePill { updateMonitor.checkForUpdates() }
                .padding(.top, 0)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Floating chip that appears in scrollback when new bubbles
    /// arrive. Tap jumps to the latest. Wrapped in `.transition` so
    /// the parent `.animation(value: pillVisible)` modifier gets a
    /// proper enter/exit motion rather than a hard cut.
    @ViewBuilder
    private var jumpToLatestOverlay: some View {
        if didSeed, pillVisible {
            JumpToLatestPill(count: unreadInScrollback) {
                jumpToLatest()
            }
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Geometry → `ScrollEdgeState` projection. Single tick produces the
    /// tight (1pt) and loose (80pt) bottom checks plus a near-top (100pt)
    /// check that triggers history loading.
    private func scrollEdgeState(_ geometry: ScrollGeometry) -> ScrollEdgeState {
        let gap = geometry.contentSize.height
            - (geometry.contentOffset.y + geometry.containerSize.height)
        return ScrollEdgeState(
            atBottomTight: gap <= 1,
            atBottomLoose: gap <= 80,
            nearTop: geometry.contentOffset.y < 100
        )
    }

    /// Auto-follow handler. Runs on `rows.last?.id` change with
    /// `initial: true`, so the very first non-nil id triggers the
    /// cold-load seed branch. Subsequent fires are steady-state
    /// auto-follow gated on `forceFollowNextBubble || isPinnedToBottom`
    /// — non-following arrivals bump the unread counter that drives
    /// the jump-to-latest pill.
    ///
    /// Cold-load seed uses id-based `scrollTo(id:anchor:)` rather than
    /// `scrollTo(edge:)`. id-based forces LazyVStack to materialize
    /// the target row, the documented fix for the blank-viewport bug
    /// — `edge:` only goes to the bottom of currently-laid-out content,
    /// which on cold load is the top of the stack.
    private func handleLastBubbleChange(_ newID: PersistentIdentifier?) {
        guard let newID else { return }
        if !didSeed {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                scrollPosition.scrollTo(id: newID, anchor: .bottom)
            }
            return
        }
        let shouldFollow = forceFollowNextBubble || isPinnedToBottom
        if forceFollowNextBubble {
            forceFollowNextBubble = false
        }
        if shouldFollow {
            isProgrammaticallyScrolling = true
            withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.22)) {
                scrollPosition.scrollTo(id: newID, anchor: .bottom)
            }
        } else {
            unreadInScrollback += 1
        }
    }

    /// Geometry-tick handler. Three responsibilities, all driven from
    /// the single bottom-distance derivation:
    ///   - first reveal — `atBottomTight` flips `didSeed` so the list
    ///     fades in once the seed has actually landed.
    ///   - auto-follow gate — `atBottomLoose` mirrors into
    ///     `isPinnedToBottom`. Loose threshold so a few pixels of
    ///     give don't kick the user out of pinned state.
    ///   - unread reset — returning to the bottom clears the pill.
    private func handleScrollEdgeState(_ snap: ScrollEdgeState) {
        if !didSeed, snap.atBottomTight {
            withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.18)) {
                didSeed = true
            }
        }
        if isProgrammaticallyScrolling {
            if snap.atBottomTight {
                isProgrammaticallyScrolling = false
                isPinnedToBottom = true
            }
            // Skip the normal isPinnedToBottom update while mid-animation.
            // Intermediate geometry ticks during the scroll would otherwise
            // transiently set isPinnedToBottom = false, causing the next
            // concurrent arrival to be miscounted as unread.
        } else {
            if isPinnedToBottom != snap.atBottomLoose {
                isPinnedToBottom = snap.atBottomLoose
            }
        }
        if snap.atBottomLoose, unreadInScrollback != 0 {
            unreadInScrollback = 0
        }
        // Trigger history load when the user scrolls near the top.
        // `needsScrollRestoreID == nil` prevents double-firing while the
        // previous load is still in flight (restore clears it post-prepend).
        if didSeed,
           snap.nearTop,
           store.hasOlderMessages,
           !store.isLoadingOlderMessages,
           needsScrollRestoreID == nil,
           let anchorID = cachedRows.first?.id {
            needsScrollRestoreID = anchorID
            Task { await store.loadOlderMessages() }
        }
    }

    /// Belt-and-suspenders reveal. If the geometry callback never
    /// observes a bottom-tight tick (zero messages, or some
    /// unforeseen LazyVStack quirk) we still reveal after 400ms so
    /// the user never sees a stuck-invisible chat. Whatever scroll
    /// position we're at when the timer fires is what the user gets.
    private func fallbackReveal() async {
        try? await Task.sleep(for: .milliseconds(400))
        if !didSeed {
            withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.18)) {
                didSeed = true
            }
        }
    }

    /// Auto-clear the reply-chip-jump highlight ~1s after it lands.
    /// Bound to `.task(id: highlightedID)` so back-to-back jumps
    /// cancel the previous timer instead of piling up.
    private func clearHighlightAfterDelay() async {
        guard highlightedID != nil else { return }
        let pinned = highlightedID
        try? await Task.sleep(for: .seconds(1))
        if highlightedID == pinned {
            withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.4)) {
                highlightedID = nil
            }
        }
    }

    /// Pill-tap action. Jump to the latest bubble with an animated
    /// scroll. Geometry callback observes the resulting `atBottomLoose`
    /// and resets `unreadInScrollback` to zero, which dismisses the
    /// pill via the `pillVisible` predicate.
    private func jumpToLatest() {
        guard let lastID = cachedRows.last?.id else { return }
        withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.28)) {
            scrollPosition.scrollTo(id: lastID, anchor: .bottom)
        }
    }

    /// Tap-to-jump from a reply chip. Centers the parent in the
    /// viewport and sets `highlightedID` so the row flashes briefly.
    /// The `.task(id: highlightedID)` modifier on `messageList`
    /// clears the highlight after ~1s.
    private func jumpToParent(_ target: CachedMessage) {
        let pid = target.persistentModelID
        withAnimation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.32)) {
            scrollPosition.scrollTo(id: pid, anchor: .center)
        }
        highlightedID = pid
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

        // Sending while in scrollback is an explicit "I'm here, in
        // the conversation" act — yank the user to the bottom on the
        // next bubble arrival regardless of `isPinnedToBottom`. The
        // store inserts the optimistic row inside the Task below;
        // when @Query observes it, our auto-follow handler picks up
        // this flag, follows once, and resets it.
        forceFollowNextBubble = true

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

        // GIF must be intercepted before the generic NSImage check.
        // NSImage can load GIFs but drops all frames when round-tripped
        // through loadObject — we get a static first frame. Requesting
        // raw bytes via loadDataRepresentation preserves the animation.
        if provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.gif.identifier) { data, error in
                guard let data, error == nil else {
                    DispatchQueue.main.async { shakeTrigger += 1 }
                    return
                }
                DispatchQueue.main.async { preparePicked(gifData: data) }
            }
            return
        }

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
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try self.pipeline.prepare(url: url)
                }.value
                imageDraft = prepared
            } catch {
                shakeTrigger += 1
            }
        }
    }

    private func preparePicked(gifData: Data) {
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try self.pipeline.prepare(gifData: gifData)
                }.value
                imageDraft = prepared
            } catch {
                shakeTrigger += 1
            }
        }
    }

    private func preparePicked(image: NSImage) {
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try self.pipeline.prepare(image: image)
                }.value
                imageDraft = prepared
            } catch {
                shakeTrigger += 1
            }
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
/// The sweep is guarded by window identity so it only re-runs when
/// the view moves to a different window (e.g. after window restore),
/// not on every SwiftUI body re-evaluation.
private struct DisableTextFieldDrops: NSViewRepresentable {
    func makeNSView(context: Context) -> Hook { Hook() }

    func updateNSView(_ nsView: Hook, context: Context) {
        nsView.scheduleSweepIfNeeded()
    }

    final class Hook: NSView {
        private weak var lastSweptWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleSweep()
        }

        func scheduleSweepIfNeeded() {
            guard window !== lastSweptWindow else { return }
            scheduleSweep()
        }

        func scheduleSweep() {
            lastSweptWindow = window
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

/// Three thresholds derived from one geometry tick:
///   - `atBottomTight`  — flush at bottom; gates first-reveal
///   - `atBottomLoose`  — within 80pt; gates auto-follow and unread reset
///   - `nearTop`        — within 100pt of top; triggers history load
private struct ScrollEdgeState: Equatable {
    let atBottomTight: Bool
    let atBottomLoose: Bool
    let nearTop: Bool
}

/// Toolbar pill that appears on the right when Sparkle reports a new
/// version. Tapping triggers the standard Sparkle update sheet.
private struct UpdateAvailablePill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .imageScale(.medium)
                Text("Update available")
                    .font(.subheadline)
                    .fontWeight(.light)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.accentColor, in: .capsule)
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: Color.accentColor.opacity(0.25), radius: 4, y: 1)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Floating "↓ N new" chip that appears near the bottom edge of the
/// message list when new bubbles arrive while the user is reading
/// scrollback. Tapping fires the `action` closure (the parent jumps
/// the scroll to the latest bubble). Glass styling keeps it visually
/// continuous with the rest of the chrome — buttonStyle(.glass) is
/// the shipping macOS 26 affordance.
private struct JumpToLatestPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.semibold))
                Text(count == 1 ? "1 new" : "\(count) new")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glassProminent)
        .tint(.curvyBrand)
    }
}

