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
    @Query(sort: \CachedMessage.createdAt) private var messages: [CachedMessage]

    @State private var draftText: String = ""
    @State private var imageDraft: ImagePipeline.Prepared?
    @State private var replyingTo: CachedMessage?
    @State private var scrollAnchor: PersistentIdentifier?
    @State private var isPinnedToBottom: Bool = true
    @State private var shakeTrigger: Int = 0
    @State private var isDropTargeted: Bool = false

    private let pipeline = ImagePipeline()

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MessageComposer(
                    draftText: $draftText,
                    imageDraft: $imageDraft,
                    replyingTo: $replyingTo,
                    shakeTrigger: shakeTrigger,
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
    var id: PersistentIdentifier { message.persistentModelID }
}

