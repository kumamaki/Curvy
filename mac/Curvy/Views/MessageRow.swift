import AppKit
import SwiftUI

/// One message in the room — bubble plus optional sender label,
/// optional reply-thread preview, and the menu plumbing for reply
/// and copy. Outgoing bubbles fill `.tint` (Curvy's brand orange)
/// and have a small "tail corner" at bottom-trailing; incoming
/// bubbles use `curvyInk` (near-black) and tail at bottom-leading.
/// The asymmetric corner radius is the same trick Telegram desktop
/// uses to communicate sender direction without resorting to a drawn
/// path that has to be hand-tuned.
///
/// Reply discoverability: right-click for the native macOS context
/// menu, or hover the bubble to reveal a small reply button beside
/// it. Hovering also surfaces the send-time on the opposite side —
/// the same affordance Slack desktop uses.
struct MessageRow: View {
    let message: CachedMessage
    let isMine: Bool
    let showSenderLabel: Bool
    let replyTarget: CachedMessage?
    let reactions: MessageReactions
    /// Resolved @-mention targets for this row's body. Each match
    /// carries both the canonical `name` (matches the wire `mentions`
    /// array) and the `handle` actually typed in the body (first
    /// word of `name` when unambiguous, full name otherwise).
    /// Empty array means no highlights to render. Computed by the
    /// parent so SwiftUI's Equatable short-circuit picks up changes
    /// when a new sender lands in the cache.
    let mentionResolutions: [MentionMatch]
    let mySender: String
    let reactionNamespace: Namespace.ID
    /// True for the brief (~1s) flash after a sibling row's reply
    /// chip jumped the scroll here. Drives a transient overlay on
    /// the bubble so the eye can find what it was navigated to —
    /// same affordance Slack/iMessage use after a thread jump.
    let isHighlighted: Bool
    let onReply: (CachedMessage) -> Void
    let onCopy: () -> Void
    /// Fires when the user taps this row's inline reply chip. Parent
    /// scrolls to the quoted message and flashes its highlight. Nil
    /// `replyTarget` means there's no chip to tap, so the closure is
    /// only invoked when there's a target to jump to.
    let onJumpToReplyParent: (CachedMessage) -> Void
    /// Tapback resolver: caller decides whether to send or remove
    /// based on `alreadyMine`. We pre-resolve the boolean here (rather
    /// than re-querying the store) because the aggregated state passed
    /// in via `reactions` is the authoritative truth at render time.
    let onToggleReaction: (String, Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var isHoveringReply: Bool = false
    @State private var isHoveringReact: Bool = false
    @State private var showingReactionPicker: Bool = false
    /// Decoded NSImage cache. Loaded once via `.task(id:)` when the
    /// underlying asset (or its on-disk timestamp) changes — never on
    /// scroll-induced body re-eval. Without this, every parent body
    /// refresh re-allocates an NSImage from disk per visible row.
    @State private var cachedImage: NSImage?

    private let bubbleCorner: CGFloat = 16
    private let bubbleTailCorner: CGFloat = 4

    private var mineByEmoji: Set<String> {
        Set(reactions.groups.compactMap { $0.senders.contains(mySender) ? $0.emoji : nil })
    }

    private func isReactionMine(_ emoji: String) -> Bool {
        mineByEmoji.contains(emoji)
    }

    var body: some View {
        if message.kind == .weird {
            weirdBubble
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
                .transition(weirdInsertionTransition)
        } else {
            HStack(spacing: 0) {
                if isMine { Spacer(minLength: 60) }

                bubbleColumn
                    .opacity(isOptimistic ? 0.65 : 1.0)
                    .contextMenu { contextMenuItems }
                    .popover(isPresented: $showingReactionPicker, arrowEdge: .bottom) {
                        ReactionPicker(
                            targetID: String(message.id),
                            mineByEmoji: mineByEmoji,
                            namespace: reactionNamespace,
                            onPick: { emoji in
                                showingReactionPicker = false
                                onToggleReaction(emoji, isReactionMine(emoji))
                            }
                        )
                        .padding(4)
                    }

                if !isMine { Spacer(minLength: 60) }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(reduceMotion ? .linear(duration: 0) : .easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .transition(insertionTransition)
        }
    }

    // MARK: - Transitions

    /// Outgoing bubbles "leap" from the composer's bottom-trailing
    /// corner with a pronounced scale + lift that mimics iMessage's
    /// send animation. Incoming bubbles "land" gently from just below.
    /// Different shapes communicate different agency: *I did this* vs.
    /// *this arrived*.
    private var insertionTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        if isMine {
            return .scale(scale: 0.6, anchor: .bottomTrailing)
                .combined(with: .opacity)
                .combined(with: .offset(y: 14))
        } else {
            return .offset(y: 6).combined(with: .opacity)
        }
    }

    private var weirdInsertionTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity)
    }

    // MARK: - Subviews

    private var timestampText: some View {
        Text(message.sentAt, format: .dateTime.hour().minute())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .accessibilityLabel("Sent at \(message.sentAt.formatted(date: .omitted, time: .shortened))")
    }

    /// Visible whenever the row is hovered OR any inline action button
    /// is hovered. The OR is what makes the buttons reachable: when
    /// the cursor crosses the 6pt gap between bubble and button, the
    /// row's hover briefly drops (the bubble has its own gesture/menu
    /// layers which interrupt parent hover propagation), but each
    /// button's own onHover latches `showActions` true before
    /// visibility collapses. The picker being open also pins the
    /// buttons visible — closing the popover by clicking outside
    /// shouldn't immediately hide the smiley that opened it.
    private var showActions: Bool {
        isHovered || isHoveringReply || isHoveringReact || showingReactionPicker
    }

    private var replyButton: some View {
        Button {
            onReply(message)
        } label: {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHoveringReply ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background(.fill.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(showActions ? 1 : 0)
        .offset(x: showActions ? 0 : (isMine ? 6 : -6))
        .scaleEffect(isHoveringReply ? 1.08 : 1.0, anchor: .center)
        .animation(reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.12), value: isHoveringReply)
        .onHover { hovering in
            isHoveringReply = hovering
        }
        .help("Reply")
        .accessibilityLabel("Reply")
        .allowsHitTesting(showActions)
    }

    /// Hover-revealed smiley button that opens the tapback picker.
    /// Mirrors the geometry, hover bounce, and offset-while-hidden
    /// trick of `replyButton` — they're siblings that read as one
    /// affordance. The bounce-on-tap symbol effect is borrowed from
    /// the composer's send button so reactions feel tactilely
    /// consistent with sends.
    private var reactButton: some View {
        Button {
            withAnimation(reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.82)) {
                showingReactionPicker.toggle()
            }
        } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHoveringReact || showingReactionPicker ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background(.fill.quaternary, in: Circle())
                .contentShape(Circle())
                .symbolEffect(.bounce.up.byLayer, options: .speed(1.4), value: showingReactionPicker)
        }
        .buttonStyle(.plain)
        .opacity(showActions ? 1 : 0)
        .offset(x: showActions ? 0 : (isMine ? 6 : -6))
        .scaleEffect(isHoveringReact ? 1.08 : 1.0, anchor: .center)
        .animation(reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.12), value: isHoveringReact)
        .onHover { hovering in
            isHoveringReact = hovering
        }
        .help("React")
        .accessibilityLabel("React")
        .allowsHitTesting(showActions)
    }

    /// Whether this message is in its "not yet committed" optimistic
    /// state — pending text or pending image. Drives the 0.65 opacity
    /// affordance that solidifies to 1.0 on commit.
    private var isOptimistic: Bool {
        message.kind == .pending || message.kind == .pendingImage
    }

    /// Whether this row carries an image (confirmed or pending).
    private var isImage: Bool {
        message.kind == .image || message.kind == .pendingImage
    }

    private var bubbleColumn: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
            if showSenderLabel && !isMine {
                Text(message.sender.isEmpty ? "—" : message.sender)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 11)
                    .padding(.bottom, 1)
            }

            HStack(spacing: 6) {
                if isMine {
                    timestampText.opacity(isHovered ? 1 : 0)
                    reactButton
                    replyButton
                }

                messageBody
                    .overlay {
                        // Reply-chip-jump highlight. Bubble-shaped
                        // brand-orange stroke that fades in/out around
                        // the row that was navigated to. The animation
                        // value swap on `isHighlighted` is what makes
                        // the appearance/disappearance feel alive
                        // rather than instant.
                        if isHighlighted {
                            bubbleShape
                                .strokeBorder(
                                    Color.curvyBrand,
                                    style: StrokeStyle(lineWidth: 2)
                                )
                                .transition(.opacity)
                        }
                    }
                    .animation(
                        reduceMotion ? .linear(duration: 0) : .easeInOut(duration: 0.28),
                        value: isHighlighted
                    )

                if !isMine {
                    replyButton
                    reactButton
                    timestampText.opacity(isHovered ? 1 : 0)
                }
            }
        }
    }

    /// The bubble itself — text or image. Reactions, when present,
    /// live INSIDE the bubble at the bottom (Telegram-style): the
    /// bubble's own background contains them, the bubble grows
    /// vertically to fit, and there's no overlay/anchor geometry
    /// fighting with bubble width or neighbors.
    @ViewBuilder
    private var messageBody: some View {
        if isImage {
            imageBubble
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let target = replyTarget {
                    inlineReplyHeader(target)
                        .contentShape(Rectangle())
                        .onTapGesture { onJumpToReplyParent(target) }
                }

                VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
                    PilledBody(text: message.body,
                              mentions: mentionResolutions,
                              myName: mySender)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.white)

                    if !reactions.groups.isEmpty {
                        ReactionBadgeStack(
                            reactions: reactions,
                            mySender: mySender,
                            namespace: reactionNamespace,
                            isMine: isMine,
                            onToggle: { emoji in
                                onToggleReaction(emoji, isReactionMine(emoji))
                            }
                        )
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
            }
            .background { bubbleBackground }
            .clipShape(bubbleShape)
        }
    }

    /// Where the reaction overlay anchors inside an image bubble.
    /// Same side as the tail to match text bubbles, where reactions
    /// inside the inner VStack align to the same edge as the sender:
    /// mine → bottom-trailing, incoming → bottom-leading. Keeps the
    /// badges' horizontal position consistent across image, text, and
    /// caption rows.
    private var imageReactionAlignment: Alignment {
        isMine ? .bottomTrailing : .bottomLeading
    }

/// Image-rendering branch. The image is the bubble: same asymmetric
    /// corner radius as text bubbles (clipShape), no fill behind it
    /// (the image fills the slot). Caption rides under the image as a
    /// separate text bubble, so reply parents and captions still get
    /// the bubble treatment for legibility while the image stays
    /// edge-to-edge inside its own clipped frame.
    ///
    /// Layout slot is reserved using `imageWidth/Height` from the
    /// envelope so the bubble doesn't visually jump when the local
    /// cache fills in async — the placeholder ProgressView and the
    /// final image both occupy the same computed frame.
    @ViewBuilder
    private var imageBubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                if let target = replyTarget {
                    inlineReplyHeader(target)
                        .frame(width: imageDisplaySize.width, alignment: .leading)
                        .background(isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.curvyInk))
                        .contentShape(Rectangle())
                        .onTapGesture { onJumpToReplyParent(target) }
                }

                ZStack {
                    if let nsImage = cachedImage {
                        if message.imageMime == "image/gif" {
                            AnimatedGIFView(image: nsImage)
                                .scaledToFill()
                        } else {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFill()
                        }
                    } else {
                        Rectangle()
                            .fill(.fill.quaternary)
                            .overlay {
                                ProgressView()
                                    .controlSize(.small)
                            }
                    }
                }
                .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                .background(.fill.quaternary)
            }
            .clipShape(bubbleShape)
            .contentShape(bubbleShape)
            .onTapGesture(count: 2) { openQuickLook() }
            .task(id: imageCacheToken) {
                cachedImage = localImageURL.flatMap { NSImage(contentsOfFile: $0.path) }
            }
            // Reactions-only (no caption): float the badge stack inside
            // the clipped image at the corner opposite the tail, with a
            // glass capsule behind it so the chips stay legible against
            // arbitrary photo content. Reactions read as part of the
            // image container rather than a separate message bubble.
            .overlay(alignment: imageReactionAlignment) {
                if message.body.isEmpty && !reactions.groups.isEmpty {
                    ReactionBadgeStack(
                        reactions: reactions,
                        mySender: mySender,
                        namespace: reactionNamespace,
                        isMine: isMine,
                        onToggle: { emoji in
                            onToggleReaction(emoji, isReactionMine(emoji))
                        }
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .padding(8)
                }
            }

            // Caption (with or without reactions): one tinted sub-bubble
            // under the image, mirroring the Telegram-style "metadata
            // lives in the bubble" principle for text messages.
            if !message.body.isEmpty {
                VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
                    PilledBody(text: message.body,
                              mentions: mentionResolutions,
                              myName: mySender)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color.white)

                    if !reactions.groups.isEmpty {
                        ReactionBadgeStack(
                            reactions: reactions,
                            mySender: mySender,
                            namespace: reactionNamespace,
                            isMine: isMine,
                            onToggle: { emoji in
                                onToggleReaction(emoji, isReactionMine(emoji))
                            }
                        )
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background { bubbleBackground }
                .frame(maxWidth: imageDisplaySize.width, alignment: isMine ? .trailing : .leading)
            }
        }
    }

    /// Cache key for the on-disk image. Changes when the asset path
    /// rotates (pending → committed) or when BlobFetcher writes the
    /// decrypted bytes and bumps `imageCachedAt`. Stable across scroll
    /// re-renders, so `.task(id:)` won't re-fire purely from scroll.
    private var imageCacheToken: String {
        if message.kind == .pendingImage {
            return "pending:\(message.id)"
        }
        if let path = message.assetPath {
            let stamp = message.imageCachedAt?.timeIntervalSince1970 ?? 0
            return "asset:\(path):\(stamp)"
        }
        return "missing:\(message.id)"
    }

    /// During an optimistic image send, the JPEG bytes get stashed at
    /// `pending-<id>.jpg` in the cache dir under the negative pending
    /// id. Until `commitPendingImage` re-links it, that's where the
    /// preview lives.
    private var pendingSidecarURL: URL? {
        guard message.kind == .pendingImage else { return nil }
        let pendingFilename = "pending-\(abs(message.id)).jpg"
        return BlobFetcher.cacheDirectory.appending(path: pendingFilename, directoryHint: .notDirectory)
    }

    /// First on-disk URL for the row's image, preferring the
    /// confirmed cache path and falling back to the pending sidecar.
    /// Returns nil while the bubble is still showing the placeholder.
    /// Trusts `imageCachedAt` as the cache-presence signal — set by
    /// BlobFetcher when the file lands and by sendImage for pending
    /// sidecars — avoiding synchronous stat(2) calls in the view body.
    private var localImageURL: URL? {
        guard message.imageCachedAt != nil else { return nil }
        if let assetPath = message.assetPath {
            return BlobFetcher.cacheURL(for: assetPath)
        }
        return pendingSidecarURL
    }

    /// Hand the cached plaintext to the system Quick Look panel. No-op
    /// while the image is still downloading — the bubble is showing a
    /// placeholder, so there's nothing to preview yet.
    private func openQuickLook() {
        guard let url = localImageURL else { return }
        let previewURL = QuickLookManager.shared.previewURL(for: url, mime: message.imageMime)
        QuickLookManager.shared.show(previewURL)
    }

    /// Bubble-sized image display size, capped at 360pt on the longer
    /// side (chat bubble feel) and never wider than the message
    /// column's 460pt cap. Falls back to a square 200pt placeholder
    /// when dimensions aren't yet known.
    private var imageDisplaySize: CGSize {
        let maxLong: CGFloat = 360
        let widthCap: CGFloat = 460
        guard let w = message.imageWidth, let h = message.imageHeight, w > 0, h > 0 else {
            return CGSize(width: 200, height: 200)
        }
        let wF = CGFloat(w)
        let hF = CGFloat(h)
        let longest = max(wF, hF)
        let scale = min(1, maxLong / longest)
        let scaledW = min(wF * scale, widthCap)
        let scaledH = hF * (scaledW / wF)
        guard scaledW.isFinite, scaledH.isFinite, scaledW > 0, scaledH > 0 else {
            return CGSize(width: 200, height: 200)
        }
        return CGSize(width: scaledW, height: scaledH)
    }

    /// Reusable shape for `clipShape` + a fill of the same shape behind
    /// the image. Same asymmetric corner as `bubbleBackground`, just
    /// extracted as a Shape so `clipShape` can take it.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: bubbleCorner,
            bottomLeadingRadius: isMine ? bubbleCorner : bubbleTailCorner,
            bottomTrailingRadius: isMine ? bubbleTailCorner : bubbleCorner,
            topTrailingRadius: bubbleCorner,
            style: .continuous
        )
    }

    /// Asymmetric rounded rect: full radius on three corners, tiny
    /// radius on the corner closest to the sender's edge of the
    /// screen. Reads as a subtle "tail" pointing toward who sent it.
    /// Mine = brand orange; others = solid black, for high contrast
    /// on the glass window background and to lean away from the
    /// orange-everywhere look.
    private var bubbleBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: bubbleCorner,
            bottomLeadingRadius: isMine ? bubbleCorner : bubbleTailCorner,
            bottomTrailingRadius: isMine ? bubbleTailCorner : bubbleCorner,
            topTrailingRadius: bubbleCorner,
            style: .continuous
        )
        .fill(isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.curvyInk))
    }

    /// Reply quote rendered as a "header section" inside the bubble's
    /// own clipped surface, Telegram/WhatsApp-style. Sits flush at the
    /// top of the bubble; a leading-edge stripe + a soft tint overlay
    /// differentiate it from the body without breaking the bubble's
    /// continuity.
    ///
    /// Color choice: foreground colors are pinned to explicit white
    /// opacities (not `.secondary`) because `.secondary` resolves
    /// against system surfaces, not against our custom orange/ink
    /// bubble fills — on `curvyInk` it desaturates to near-charcoal.
    /// Outgoing uses a white-tint overlay (slightly paler orange band).
    /// Incoming uses the brand tint at low opacity so the band reads
    /// as a *warmer* slice of the same dark surface, picking up the
    /// stripe color instead of stamping a gray rectangle on top.
    /// Image originals get a small `photo` glyph and a "Photo"
    /// fallback when the parent had no caption.
    private func inlineReplyHeader(_ target: CachedMessage) -> some View {
        let stripeStyle: AnyShapeStyle = isMine
            ? AnyShapeStyle(Color.white.opacity(0.55))
            : AnyShapeStyle(Color.curvyBrand.opacity(0.6))
        let senderStyle: AnyShapeStyle = isMine
            ? AnyShapeStyle(Color.white)
            : AnyShapeStyle(.tint)
        let bodyStyle: AnyShapeStyle = isMine
            ? AnyShapeStyle(Color.white.opacity(0.72))
            : AnyShapeStyle(Color.white.opacity(0.62))
        let overlayStyle: AnyShapeStyle = isMine
            ? AnyShapeStyle(Color.white.opacity(0.18))
            : AnyShapeStyle(Color.curvyBrand.opacity(0.14))
        let isImageTarget = target.kind == .image || target.kind == .pendingImage
        let bodyText: String = {
            if target.kind == .weird { return "weird message" }
            if isImageTarget && target.body.isEmpty { return "Photo" }
            return target.body
        }()

        return HStack(spacing: 8) {
            // Fixed stripe height (rather than stretch-to-fill) so the
            // rule reads as a quote-mark accent next to the text, not
            // a full-bleed sidebar. Sized to roughly hug the two-line
            // text block — the HStack's `.center` alignment pins it
            // vertically against the sender + body pair.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(stripeStyle)
                .frame(width: 2.5, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(target.sender.isEmpty ? "—" : target.sender)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(senderStyle)

                HStack(spacing: 4) {
                    if isImageTarget {
                        Image(systemName: "photo")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(bodyStyle)
                    }
                    Text(bodyText)
                        .font(.system(size: 11))
                        .foregroundStyle(bodyStyle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: 280, alignment: .leading)
        .background(overlayStyle)
    }

    private var weirdBubble: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.diamond.fill")
                .font(.callout)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: .nonRepeating, value: message.id)
            Text("weird message detected")
                .font(.callout.italic())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                    .fill(.fill.quaternary)
                RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                    .strokeBorder(
                        Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
        }
        .help("Comment <\(message.id)> couldn't be decrypted")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            onReply(message)
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        Button {
            withAnimation(reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.82)) {
                showingReactionPicker = true
            }
        } label: {
            Label("React", systemImage: "face.smiling")
        }
        Button {
            onCopy()
        } label: {
            Label("Copy", systemImage: "document.on.document")
        }
        if isImage, localImageURL != nil {
            Button {
                openQuickLook()
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
        }
    }

}

/// View-level `Equatable` for SwiftUI's `.equatable()` short-circuit:
/// when ChatView re-evaluates its body during scroll (driven by the
/// `.scrollPosition` binding writeback), this lets SwiftUI skip every
/// visible row's body unless one of its rendering inputs actually
/// changed. Closures (`onReply`, `onCopy`, `onToggleReaction`) and the
/// `Namespace.ID` are intentionally excluded — closures are recreated
/// every render but functionally identical, and the namespace is
/// constant for ChatView's lifetime.
///
/// CachedMessage is a SwiftData `@Model` *class*, so we compare its
/// rendering-relevant scalar fields, not `===` — the same instance can
/// have mutated fields (e.g. `imageCachedAt` flipping nil → Date when
/// BlobFetcher writes the decrypted bytes) and we must not skip the
/// re-render in that case.
extension MessageRow: @MainActor Equatable {
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.persistentModelID == rhs.message.persistentModelID
            && lhs.message.id == rhs.message.id
            && lhs.message.body == rhs.message.body
            && lhs.message.kind == rhs.message.kind
            && lhs.message.sender == rhs.message.sender
            && lhs.message.sentAt == rhs.message.sentAt
            && lhs.message.imageCachedAt == rhs.message.imageCachedAt
            && lhs.message.assetPath == rhs.message.assetPath
            && lhs.message.imageWidth == rhs.message.imageWidth
            && lhs.message.imageHeight == rhs.message.imageHeight
            && lhs.replyTarget?.persistentModelID == rhs.replyTarget?.persistentModelID
            && lhs.replyTarget?.body == rhs.replyTarget?.body
            && lhs.replyTarget?.sender == rhs.replyTarget?.sender
            && lhs.replyTarget?.kind == rhs.replyTarget?.kind
            && lhs.isMine == rhs.isMine
            && lhs.showSenderLabel == rhs.showSenderLabel
            && lhs.mySender == rhs.mySender
            && lhs.reactions == rhs.reactions
            && lhs.mentionResolutions == rhs.mentionResolutions
            && lhs.isHighlighted == rhs.isHighlighted
    }
}

/// Renders a chat message body with `@<token>` spans displayed as
/// inline white-capsule pills containing brand-orange semibold text.
/// Plain text segments inherit the bubble's font + foreground style
/// (white) just like before; pill segments are explicit subviews
/// with their own background + foreground.
///
/// Layout uses a custom `Layout` (`PillFlowLayout`) so pills and
/// text segments flow inline and wrap to additional lines when the
/// available width runs out.
private struct PilledBody: View {
    let text: String
    let mentions: [MentionMatch]
    let myName: String

    var body: some View {
        let segments = makeSegments(body: text, mentions: mentions, myName: myName)
        PillFlowLayout(horizontalSpacing: 0, lineSpacing: 1) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .plain(let plain):
                    Text(plain)
                case .pill(_, let token, _):
                    Text("@" + token)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.curvyBrand)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.white, in: Capsule())
                case .link(let text, let url):
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(text)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

/// One contiguous slice of body text, either plain (rendered as a
/// `Text`) or a mention pill (rendered with capsule background).
private enum BodySegment {
    case plain(String)
    case pill(name: String, token: String, isSelf: Bool)
    case link(text: String, url: URL)
}

/// Walk `body`, finding every `@<token>` span that resolves against
/// `mentions`, and emit alternating plain + pill segments. Delegates
/// the `@`-mention boundary scanning to `MentionResolver.pillRanges`
/// so the rules stay in one place.
private func makeSegments(
    body: String,
    mentions: [MentionMatch],
    myName: String
) -> [BodySegment] {
    if body.isEmpty { return [] }
    if mentions.isEmpty { return splitByLinks(body) }

    let pillRanges = MentionResolver.pillRanges(in: body, resolutions: mentions)

    var segments: [BodySegment] = []
    var cursor = body.startIndex
    for pill in pillRanges {
        if cursor < pill.range.lowerBound {
            segments.append(.plain(String(body[cursor..<pill.range.lowerBound])))
        }
        segments.append(.pill(
            name: pill.name,
            token: pill.token,
            isSelf: pill.name == myName
        ))
        cursor = pill.range.upperBound
    }
    if cursor < body.endIndex {
        segments.append(.plain(String(body[cursor..<body.endIndex])))
    }
    return segments.flatMap { segment in
        if case .plain(let text) = segment { return splitByLinks(text) }
        return [segment]
    }
}

/// NSDataDetector construction is expensive (compiles an internal
/// regex), so we share one instance for the lifetime of the process.
private let linkDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
)

/// Scan a plain-text string for URLs and split it into interleaved
/// `.plain` and `.link` segments. Runs after mention detection so
/// patterns like `@alice.com` are already claimed as pills before
/// NSDataDetector sees them.
private func splitByLinks(_ plain: String) -> [BodySegment] {
    guard let detector = linkDetector, !plain.isEmpty else { return [.plain(plain)] }

    let matches = detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
    guard !matches.isEmpty else { return [.plain(plain)] }

    var result: [BodySegment] = []
    var cursor = plain.startIndex
    for match in matches {
        guard let url = match.url, let range = Range(match.range, in: plain) else { continue }
        if cursor < range.lowerBound {
            result.append(.plain(String(plain[cursor..<range.lowerBound])))
        }
        result.append(.link(text: String(plain[range]), url: url))
        cursor = range.upperBound
    }
    if cursor < plain.endIndex {
        result.append(.plain(String(plain[cursor...])))
    }
    return result
}

/// Wrapping inline-flow layout. Each subview takes its natural size
/// and gets placed left-to-right; when the next subview won't fit on
/// the current line it wraps to the next. Keeps `lineHeight` per
/// line so pills (slightly taller than plain text) don't push earlier
/// segments downward — alignment is to the line top, baseline drift
/// is acceptable for a chat bubble.
private struct PillFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 0
    var lineSpacing: CGFloat = 0

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return computeLayout(maxWidth: maxWidth, subviews: subviews).totalSize
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let layout = computeLayout(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func computeLayout(
        maxWidth: CGFloat,
        subviews: Subviews
    ) -> (frames: [CGRect], totalSize: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxRight: CGFloat = 0
        for sub in subviews {
            let idealSize = sub.sizeThatFits(.unspecified)
            // Wrap to next line if segment doesn't fit and we're not at line start.
            if x > 0 && x + idealSize.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            // Constrain to remaining line width so Text re-flows vertically.
            let available = maxWidth - x
            let placedWidth = min(idealSize.width, available)
            let placedHeight = placedWidth < idealSize.width
                ? sub.sizeThatFits(ProposedViewSize(width: placedWidth, height: nil)).height
                : idealSize.height
            frames.append(CGRect(x: x, y: y, width: placedWidth, height: placedHeight))
            x += placedWidth + horizontalSpacing
            lineHeight = max(lineHeight, placedHeight)
            maxRight = max(maxRight, x - horizontalSpacing)
        }
        return (frames, CGSize(width: maxRight, height: y + lineHeight))
    }
}

