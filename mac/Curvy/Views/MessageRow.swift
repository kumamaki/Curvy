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
    let onReply: (CachedMessage) -> Void
    let onCopy: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var isHoveringReply: Bool = false

    private let bubbleCorner: CGFloat = 16
    private let bubbleTailCorner: CGFloat = 4

    var body: some View {
        if message.kind == .weird {
            weirdBubble
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
                .transition(weirdInsertionTransition)
        } else {
            HStack(spacing: 6) {
                if isMine {
                    Spacer(minLength: 60)
                    timestampText.opacity(isHovered ? 1 : 0)
                    replyButton
                }

                bubbleColumn
                    .opacity(isOptimistic ? 0.65 : 1.0)
                    .contextMenu { contextMenuItems }

                if !isMine {
                    replyButton
                    timestampText.opacity(isHovered ? 1 : 0)
                    Spacer(minLength: 60)
                }
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

    /// Visible whenever the row is hovered OR the button itself is
    /// hovered. The OR is what makes the button reachable: when the
    /// cursor crosses the 6pt gap between bubble and button, the row's
    /// hover briefly drops (the bubble has its own gesture/menu layers
    /// which interrupt parent hover propagation), but the button's own
    /// onHover latches `showActions` true before visibility collapses.
    private var showActions: Bool {
        isHovered || isHoveringReply
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

            if let target = replyTarget {
                replyPreview(target)
            }

            if isImage {
                imageBubble
            } else {
                Text(message.body)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background { bubbleBackground }
                    .foregroundStyle(Color.white)
            }
        }
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
            ZStack {
                if let nsImage = loadedImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
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
            .clipShape(bubbleShape)
            .background(bubbleShape.fill(.fill.quaternary))
            .contentShape(bubbleShape)
            .onTapGesture(count: 2) { openQuickLook() }

            if !message.body.isEmpty {
                Text(message.body)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background { bubbleBackground }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: imageDisplaySize.width, alignment: isMine ? .trailing : .leading)
            }
        }
    }

    /// Best available local image: real file from the cache for
    /// `.image`, the pending sidecar for `.pendingImage`. Returns nil
    /// when nothing's on disk — caller renders the placeholder.
    private var loadedImage: NSImage? {
        guard let assetPath = message.assetPath else {
            // Pending row before its sidecar landed — fall through to placeholder.
            return pendingSidecarImage
        }
        let url = BlobFetcher.cacheURL(for: assetPath)
        if FileManager.default.fileExists(atPath: url.path) {
            return NSImage(contentsOfFile: url.path)
        }
        return pendingSidecarImage
    }

    /// During an optimistic image send, the JPEG bytes get stashed at
    /// `pending-<id>.jpg` in the cache dir under the negative pending
    /// id. Until `commitPendingImage` re-links it, that's where the
    /// preview lives.
    private var pendingSidecarImage: NSImage? {
        guard let url = pendingSidecarURL else { return nil }
        return NSImage(contentsOfFile: url.path)
    }

    private var pendingSidecarURL: URL? {
        guard message.kind == .pendingImage else { return nil }
        let pendingFilename = "pending-\(abs(message.id)).jpg"
        return BlobFetcher.cacheDirectory.appending(path: pendingFilename, directoryHint: .notDirectory)
    }

    /// First on-disk URL for the row's image, preferring the
    /// confirmed cache path and falling back to the pending sidecar.
    /// Returns nil while the bubble is still showing the placeholder.
    private var localImageURL: URL? {
        if let assetPath = message.assetPath {
            let url = BlobFetcher.cacheURL(for: assetPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let url = pendingSidecarURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
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

    private func replyPreview(_ target: CachedMessage) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(.tint)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.sender.isEmpty ? "—" : target.sender)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(target.kind == .weird ? "weird message" : target.body)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.fill.quaternary, in: .rect(cornerRadius: 8))
        .frame(maxWidth: 280, alignment: isMine ? .trailing : .leading)
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

