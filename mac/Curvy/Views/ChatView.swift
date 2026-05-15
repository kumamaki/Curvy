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
    // Imperative scroll API for jump-to-latest, jump-to-parent, and
    // post-prepend restore. Initialized to `.bottom` so the very first
    // External scroll requests (scene resume, jump-to-latest,
    // jump-to-parent) route through this state. The onChange inside
    // ScrollViewReader consumes it and calls proxy.scrollTo.
    @State private var externalScroll: ExternalScrollRequest?
    @State private var isPinnedToBottom: Bool = true
    // Flips true the first time `cachedRows` becomes non-empty. Used to
    // gate the push-up animation (the initial cold-load shouldn't
    // animate — it's not an insert, it's the world appearing) and the
    // jump-to-latest pill (which would otherwise flash on cold load
    // before scroll geometry settles).
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
    // Set just before triggering `loadOlderMessages()` to the ID of the
    // top-most visible row. After the prepend lands, `handleMessages-
    // Change` scrolls back to this row so the user's reading position
    // stays stable.
    @State private var needsScrollRestoreID: PersistentIdentifier?

    /// Shared namespace for the reaction "stick" animation. Picker
    /// emojis publish a matched-geometry source keyed by
    /// `(targetID, emoji)`; the badge that lands on the bubble corner
    /// publishes the matching destination. SwiftUI animates the emoji
    /// between them — same motion iMessage uses on tapback landing.
    @Namespace private var reactionNamespace

    /// Bumped by `send()` to retrigger the composer's send-button
    /// pulse animation — a tinted Circle behind the icon that scales
    /// up and fades. Cheap visual ack of the tap that doesn't depend
    /// on cross-view matched-geometry, which we tried and abandoned
    /// (sources de-syncing with destinations + scroll-perf regression).
    @State private var sendPulseTick: Int = 0

    private let pipeline = ImagePipeline()

    var body: some View {
        messageList
            // 16pt of breathing room between the last scrollable row
            // and the composer — OUTSIDE the scroll content, so
            // `proxy.scrollTo(id, anchor: .bottom)` still lands the
            // row's bottom flush with the viewport bottom (an inner
            // `.padding(.bottom)` would silently consume the gap).
            .safeAreaInset(edge: .bottom, spacing: 16) {
                MessageComposer(
                    draftText: $draftText,
                    imageDraft: $imageDraft,
                    replyingTo: $replyingTo,
                    shakeTrigger: shakeTrigger,
                    knownSenders: cachedKnownSenders,
                    sendPulseTick: sendPulseTick,
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
                    store.kickPoll()
                    // Re-snap to the latest only if the user was at
                    // the bottom when they left. id-based scrollTo
                    // (not edge:) so LazyVStack materializes the
                    // target row — same fix as the cold-load seed.
                    // Animations disabled: the user is already
                    // looking at the screen on resume, a sudden
                    // scroll would feel jarring.
                    if wasPinnedAtBackground, let lastID = cachedRows.last?.id {
                        externalScroll = ExternalScrollRequest(id: lastID, anchor: .bottom, animated: false)
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
        let interval = AppLog.signposter.beginInterval("rows.build", "n=\(messages.count)")
        defer { AppLog.signposter.endInterval("rows.build", interval) }
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

        // Treat pending and committed states as the same group bucket
        // so the row's top padding doesn't animate from 12pt → 2pt when
        // a pending text/image commits in place. Otherwise the row
        // visibly jumps on commit — same logical message, same author.
        func bucket(_ kind: CachedMessage.Kind) -> CachedMessage.Kind {
            switch kind {
            case .pending: return .text
            case .pendingImage: return .image
            default: return kind
            }
        }

        var prev: CachedMessage?
        var rows = bubbleMessages.map { msg -> RowItem in
            defer { prev = msg }
            let isNewGroup = prev?.sender != msg.sender
                || (prev.map { bucket($0.kind) } != bucket(msg.kind))
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
            // Show a date separator before the first message and whenever
            // the calendar day changes or the gap between messages exceeds
            // one hour — same heuristic as iMessage.
            let separatorDate: Date?
            if let prev {
                let sameDay = Calendar.current.isDate(msg.sentAt, inSameDayAs: prev.sentAt)
                let gap = msg.sentAt.timeIntervalSince(prev.sentAt)
                separatorDate = (!sameDay || gap > 3600) ? msg.sentAt : nil
            } else {
                separatorDate = msg.sentAt
            }
            return RowItem(
                message: msg,
                isMine: msg.kind != .weird && msg.sender == myName,
                isNewGroup: isNewGroup,
                isLastInGroup: false,
                replyTarget: replyParent,
                reactions: aggregated[targetKey] ?? .empty(targetID: targetKey),
                mentionResolutions: resolved,
                separatorDate: separatorDate
            )
        }
        // Second pass: set isLastInGroup by looking one step ahead.
        // A row is last when the next row is from a different sender
        // (or kind group), or when there is no next row.
        for i in rows.indices {
            let next = rows.indices.contains(i + 1) ? rows[i + 1] : nil
            rows[i].isLastInGroup = next == nil
                || next!.message.sender != rows[i].message.sender
                || bucket(next!.message.kind) != bucket(rows[i].message.kind)
        }
        return rows
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

    /// Extracted out of the `ForEach` body to keep the modifier chain
    /// inside the list short enough for the type-checker. Holds the
    /// closures and matched-geometry plumbing in one place.
    private func messageRowView(for row: RowItem) -> MessageRow {
        let targetID = String(row.message.id)
        return MessageRow(
            message: row.message,
            isMine: row.isMine,
            showSenderLabel: row.isNewGroup,
            replyTarget: row.replyTarget,
            reactions: row.reactions,
            mentionResolutions: row.mentionResolutions,
            mySender: store.displayName,
            reactionNamespace: reactionNamespace,
            isHighlighted: highlightedID == row.id,
            isLastInGroup: row.isLastInGroup,
            onReply: { replyingTo = $0 },
            onCopy: { copy(row.message) },
            onJumpToReplyParent: jumpToParent,
            onToggleReaction: { emoji, alreadyMine in
                toggleReaction(targetID: targetID, emoji: emoji, alreadyMine: alreadyMine)
            }
        )
    }

    private var messageList: some View {
        // ScrollViewReader so `proxy.scrollTo` is available inside the
        // single messages.onChange handler. `scrollPosition.scrollTo`
        // on macOS 26 doesn't animate within `withAnimation` (completes
        // synchronously, no visible scroll), so all programmatic
        // scrolls use the proxy API. We still keep `.scrollPosition`
        // for the geometry-driven pin tracking.
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                if store.isLoadingOlderMessages {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                ForEach(cachedRows) { row in
                    if let sepDate = row.separatorDate {
                        DateSeparatorView(date: sepDate)
                    }
                    messageRowView(for: row)
                        .equatable()
                        .padding(.top, row.separatorDate != nil ? 4 : row.isNewGroup ? 20 : 1)
                        .id(row.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // No bottom padding: `proxy.scrollTo(id, anchor: .bottom)`
            // aligns the row's bottom with the viewport bottom, and
            // any padding INSIDE `.scrollTargetLayout()` creates an
            // irrecoverable gap below it. Breathing room comes from
            // the composer's safe-area inset instead.
        }
        // defaultScrollAnchor pins the initial viewport to the bottom
        // on cold launch without any programmatic scrollTo call. No
        // scrollPosition binding or scrollTargetLayout: those required
        // SwiftUI to walk all 200 rows per frame to identify which one
        // was at the anchor, which was O(N) per scroll event.
        .defaultScrollAnchor(.bottom)
        .softScrollEdges()
        .onChange(of: externalScroll) { _, req in
            guard let req else { return }
            externalScroll = nil
            if req.animated {
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(req.id, anchor: req.anchor)
                }
            } else {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(req.id, anchor: req.anchor) }
            }
        }
        // XOR-reduce to a single Int rather than allocating a [Int]
        // array on every body pass (40×/sec during scroll).
        // Collisions are astronomically unlikely with monotonically-
        // increasing GitHub comment IDs; correctness is preserved.
        .onChange(of: messages.reduce(into: 0) { $0 ^= $1.id }, initial: true) { _, _ in
            Task { @MainActor in
                await handleMessagesChange(proxy: proxy)
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
        } // ScrollViewReader
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

    /// Geometry → `ScrollEdgeState` projection. 24pt slack absorbs
    /// momentum-scroll undershoot and a few pixels of inertial give
    /// without making the pill linger far above the actual bottom.
    /// The 100pt near-top threshold triggers history pagination.
    private func scrollEdgeState(_ geometry: ScrollGeometry) -> ScrollEdgeState {
        let gap = geometry.contentSize.height
            - (geometry.contentOffset.y + geometry.containerSize.height)
        return ScrollEdgeState(
            atBottom: gap <= 24,
            nearTop: geometry.contentOffset.y < 100
        )
    }

    /// Single entry point for every messages-driven scroll. Phases:
    ///
    ///   1. Rebuild `cachedRows` from `messages`. Wrap the mutation in
    ///      `withAnimation(.pushUp)` when a new tail row appeared, so
    ///      older rows visibly shift upward.
    ///   2. `await Task.yield()` — yields one runloop tick so SwiftUI's
    ///      layout pass commits the new row before the scroll resolves.
    ///      Without this, `proxy.scrollTo` targets stale geometry and
    ///      lands short. Not a magic-number delay; a runloop boundary.
    ///   3. If this is the cold-load seed, an own send, or an incoming
    ///      bubble while pinned: `proxy.scrollTo(lastID, anchor: .bottom)`.
    ///      Cold-load path disables animations so the user never sees
    ///      the snap; send/follow path animates with `SendAnimation.scroll`.
    ///   4. After history pagination: `proxy.scrollTo(anchorID, anchor: .top)`
    ///      to restore the user's reading position above the prepend.
    ///
    /// `isPinnedToBottom` is set eagerly after scrollTo; the next
    /// geometry tick corrects us if we somehow didn't land. No fake
    /// completion handler, no `isProgrammaticallyScrolling` flag —
    /// pin state is observed, not declared.
    @MainActor
    private func handleMessagesChange(proxy: ScrollViewProxy) async {
        let interval = AppLog.signposter.beginInterval("messages.change")
        defer { AppLog.signposter.endInterval("messages.change", interval) }
        let anchorID = needsScrollRestoreID
        let previousTailID = cachedRows.last?.id
        let nextRows = buildRows()
        let nextTailID = nextRows.last?.id
        let isTailInsert = didSeed
            && previousTailID != nil
            && nextTailID != nil
            && previousTailID != nextTailID
        let shouldFollow = isTailInsert && (forceFollowNextBubble || isPinnedToBottom)
        if isTailInsert {
            forceFollowNextBubble = false
        }

        AppLog.ui.pub("[rows] rebuild prev=\(cachedRows.count) next=\(nextRows.count) tailChanged=\(previousTailID != nextTailID) didSeed=\(didSeed) isTailInsert=\(isTailInsert) shouldFollow=\(shouldFollow)")

        if isTailInsert, !reduceMotion {
            withAnimation(SendAnimation.pushUp) {
                cachedRows = nextRows
            }
            if !shouldFollow {
                unreadInScrollback += 1
            }
        } else {
            cachedRows = nextRows
        }
        cachedKnownSenders = knownSenders

        let wasFirstLoad = !didSeed && !cachedRows.isEmpty
        if wasFirstLoad {
            didSeed = true
        }

        // Yield once so SwiftUI commits layout for the row mutation
        // above. proxy.scrollTo called inline here resolves against
        // pre-mutation geometry and lands short.
        await Task.yield()

        if (shouldFollow || wasFirstLoad), let lastID = nextTailID {
            if wasFirstLoad || reduceMotion {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
                AppLog.ui.pub("[scroll] instant → \(lastID)")
            } else {
                AppLog.ui.pub("[scroll] animated → \(lastID)")
                withAnimation(SendAnimation.scroll) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                } completion: {
                    // Corrective pass: when a date separator is inserted
                    // alongside the new row, its height isn't in geometry
                    // when the spring's target is resolved, so the row
                    // lands short of the viewport bottom. Snap flush after
                    // layout settles. No-op when there's no separator.
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            isPinnedToBottom = true
        }

        if let anchorID, cachedRows.contains(where: { $0.id == anchorID }) {
            needsScrollRestoreID = nil
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }

    /// Geometry tick → `isPinnedToBottom` mirror + unread reset +
    /// near-top history pagination trigger. No suppression flag: if a
    /// programmatic scroll briefly flips us off-bottom mid-spring,
    /// the next tick at `atBottom=true` restores pin and clears unread.
    private func handleScrollEdgeState(_ snap: ScrollEdgeState) {
        if isPinnedToBottom != snap.atBottom {
            AppLog.ui.pub("[geom] isPinned flip \(isPinnedToBottom) → \(snap.atBottom)")
            isPinnedToBottom = snap.atBottom
        }
        if snap.atBottom, unreadInScrollback != 0 {
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
    /// scroll. Geometry callback observes the resulting `atBottom`
    /// and resets `unreadInScrollback` to zero, which dismisses the
    /// pill via the `pillVisible` predicate.
    private func jumpToLatest() {
        guard let lastID = cachedRows.last?.id else { return }
        externalScroll = ExternalScrollRequest(id: lastID, anchor: .bottom, animated: !reduceMotion)
    }

    private func jumpToParent(_ target: CachedMessage) {
        let pid = target.persistentModelID
        externalScroll = ExternalScrollRequest(id: pid, anchor: .center, animated: !reduceMotion)
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

        // Visual ack of the send tap. Composer reads `sendPulseTick`
        // and replays a tinted-circle scale+fade behind the send glyph.
        // Cheap, view-local, doesn't touch SwiftData or the row list.
        sendPulseTick &+= 1
        AppLog.ui.pub("[send] tap → forceFollow=true pulseTick=\(sendPulseTick) isPinned=\(isPinnedToBottom) rows=\(cachedRows.count)")

        // Synchronous optimistic insert for the TEXT path. Hits
        // SwiftData on the same runloop tick as the tap, so the
        // `@Query`-driven `onChange` fires and the cachedRows update
        // (+ animation) happens microseconds later instead of the
        // ~50ms Task-scheduling delay we measured. Image sends still
        // go through the Task path below — they require an async
        // upload before the row should appear.
        let syncInserted: CachedMessage?
        if attachedImage == nil {
            do {
                syncInserted = try store.insertPendingText(text: textToSend, replyTo: replyID)
                AppLog.ui.pub("[send] sync-insert ok pending.id=\(syncInserted?.id ?? 0)")
            } catch {
                AppLog.ui.pub("[send] sync-insert failed: \(error.localizedDescription)")
                draftText = textToSend
                imageDraft = attachedImage
                shakeTrigger += 1
                return
            }
        } else {
            syncInserted = nil
        }

        Task {
            do {
                if let attachedImage {
                    try await store.sendImage(
                        prepared: attachedImage,
                        caption: captionToSend,
                        replyTo: replyID
                    )
                } else if let syncInserted {
                    try await store.uploadPendingText(
                        syncInserted,
                        text: textToSend,
                        replyTo: replyID
                    )
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
    var isLastInGroup: Bool
    let replyTarget: CachedMessage?
    let reactions: MessageReactions
    let mentionResolutions: [MentionMatch]
    var separatorDate: Date?
    var id: PersistentIdentifier { message.persistentModelID }
}

/// Programmatic scroll request for operations outside the ScrollViewReader
/// scope (scene resume, jump-to-latest pill, reply-chip jump). Set on
/// `externalScroll` state; consumed by the onChange inside the reader.
private struct ExternalScrollRequest: Equatable {
    let id: PersistentIdentifier
    let anchor: UnitPoint
    let animated: Bool
}

/// Two thresholds derived from one geometry tick:
///   - `atBottom`  — within 24pt of bottom; gates auto-follow,
///                   pin state, and unread reset
///   - `nearTop`   — within 100pt of top; triggers history load
private struct ScrollEdgeState: Equatable {
    let atBottom: Bool
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
/// continuous with the rest of the chrome on macOS 26+;
/// `adaptiveGlassProminent` falls back to bordered-prominent on 15.
private struct JumpToLatestPill: View {
    let count: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.curvyBrand.opacity(0.18))
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.curvyBrand)
                }
                .frame(width: 22, height: 22)

                HStack(spacing: 4) {
                    Text("\(count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(count == 1 ? "new message" : "new messages")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .glassyBackground(in: .capsule)
            .shadow(
                color: .black.opacity(hovering ? 0.20 : 0.12),
                radius: hovering ? 12 : 6,
                y: hovering ? 4 : 2
            )
            .scaleEffect(hovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Centered time-context separator between message groups that are
/// on different calendar days or more than an hour apart. Matches
/// iMessage's floating date pill pattern.
private struct DateSeparatorView: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.fill.quaternary, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: .now).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

