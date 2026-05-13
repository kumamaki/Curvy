import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Auto-growing text input that posts on `Return` (and `⌘+Return`)
/// and inserts a newline on `Shift+Return`. Built on
/// `TextField(axis: .vertical)` for the native Return-submits /
/// Shift-Return-newlines behaviour.
///
/// The composer card is `.regularMaterial` with a hairline `.separator`
/// border — the modern macOS Mail/Messages composer pattern, not full
/// glass, so it doesn't sample the window's glass and produce a muddy
/// double-frosted look. On a failed send the entire card briefly
/// shakes (driven by `shakeTrigger` from the parent), giving tactile
/// feedback like macOS's incorrect-password animation.
///
/// The send button is *always* tappable per design spec; empty input
/// is a silent no-op rather than a disabled button. The icon fades to
/// `.tertiary` when empty so VoiceOver users still get a state signal
/// without a `disabled` modifier.
///
/// v3 adds three image-attachment affordances, all routing into the
/// same `imageDraft` binding which the parent reads when `onSend`
/// fires:
///   - paperclip button → `.fileImporter` (NSOpenPanel under the hood)
///   - drag any image anywhere in the window (handled by `ChatView`)
///   - ⌘V on the composer pastes an image off the clipboard, but only
///     when the clipboard *has* an image — text pastes still go to
///     the text field unmolested
///
/// File-picker URLs and pasted providers don't get prepared here —
/// the composer hands them off to `ChatView` via `onLoadURL` /
/// `onLoadProviders`, which owns the `ImagePipeline` and the drop UI.
struct MessageComposer: View {
    @Binding var draftText: String
    @Binding var imageDraft: ImagePipeline.Prepared?
    @Binding var replyingTo: CachedMessage?
    let shakeTrigger: Int
    /// Snapshot of every distinct sender currently in the chat cache,
    /// owned by `ChatView`. Used to filter the autocomplete picker.
    /// We don't track picker selections separately — the body itself
    /// is the source of truth for mentions, resolved at send time
    /// inside `MessageStore.send`.
    let knownSenders: [String]
    /// Monotonic counter bumped by `ChatView.send()` for each send
    /// tap. Drives the tinted-circle pulse behind the send glyph —
    /// visual ack that the tap registered, replacing the more
    /// elaborate cross-view matched-geometry morph that didn't pay
    /// off (de-syncing source/destination plus scroll perf cost).
    let sendPulseTick: Int
    let onSend: () -> Void
    let onPickError: (any Error) -> Void
    let onLoadURL: (URL) -> Void
    let onLoadProviders: ([NSItemProvider]) -> Void

    @Environment(MessageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sendPulse: Bool = false
    @State private var showFileImporter: Bool = false

    // MARK: - Mention state
    /// Height of the autosizing NSTextView. Updated by the wrapper on
    /// each layout pass; consumed by `.frame(height:)` so the field
    /// grows with content up to `maxLines`.
    @State private var draftHeight: CGFloat = 28
    /// Substring after `@` and before the caret when the caret is
    /// inside an active mention token. `nil` means no picker is open.
    @State private var mentionQuery: String? = nil
    /// Highlighted row in the picker. Reset to 0 whenever the active
    /// query changes (so a fresh `@` always selects the top result).
    @State private var pickerSelectedIndex: Int = 0
    /// Pointer the wrapper installs a "commit @-token at caret"
    /// closure on. The picker's onSelect calls `mentionController
    /// .commit(name)` and the wrapper mutates the live NSTextView
    /// in place — avoids re-deriving the token range from the
    /// SwiftUI string, which is a class of off-by-one bugs.
    @State private var mentionController = MentionTextController()

    private var trimmed: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Anything to send? Either typed text OR an attached image counts.
    /// The send button uses this to decide its tinted-vs-tertiary look.
    private var hasContent: Bool {
        !trimmed.isEmpty || imageDraft != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let target = replyingTo {
                replyBanner(target)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .transition(replyBannerTransition)
            }
            if let draft = imageDraft {
                imagePreviewChip(draft)
                    .padding(.horizontal, 12)
                    .padding(.top, replyingTo == nil ? 8 : 4)
                    .padding(.bottom, 4)
                    .transition(replyBannerTransition)
            }
            composerRow
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .modifier(ShakeEffect(shakes: CGFloat(shakeTrigger)))
        .animation(
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.82),
            value: replyingTo?.id
        )
        .animation(
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.82),
            value: imageDraft != nil
        )
        .animation(
            reduceMotion ? .linear(duration: 0) : .linear(duration: 0.4),
            value: shakeTrigger
        )
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
    }

    private var replyBannerTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 8)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .opacity
        )
    }

    private var composerRow: some View {
        // Buttons are pinned to the bottom of the row so they ride the
        // last line when the text input grows. Each button is wrapped
        // in a `frame(height: 28)` matching the single-line text frame,
        // and given `.padding(.bottom, 9)` matching `mentionAwareInput`'s
        // `.padding(.vertical, 9)` — this lands every icon's vertical
        // centre on the same baseline as the text's vertical centre,
        // regardless of icon size.
        HStack(alignment: .bottom, spacing: 10) {
            attachButton
                .frame(height: 28)
                .padding(.bottom, 9)
            mentionAwareInput
            sendButton
                .frame(height: 28)
                .padding(.bottom, 9)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.18), value: draftText)
    }

    /// The autosizing NSTextView wrapper plus the floating mention
    /// picker overlay. Picker positions itself above the input via a
    /// negative-y offset on an `.overlay(alignment: .topLeading)` —
    /// estimated height keeps it from clipping when the picker has
    /// fewer rows than the cap (1 or 2 names is common).
    private var mentionAwareInput: some View {
        MentionTextView(
            text: $draftText,
            height: $draftHeight,
            activeQuery: $mentionQuery,
            pickerActive: !filteredSuggestions.isEmpty,
            placeholder: "Message",
            font: .systemFont(ofSize: 14),
            maxLines: 6,
            controller: mentionController,
            onSend: handleReturnSend,
            onPickerNavigate: navigatePicker,
            onPickerCommit: commitPickerSelection,
            onPickerDismiss: dismissPicker,
            onPasteImage: onLoadProviders
        )
        .frame(height: draftHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            if !filteredSuggestions.isEmpty {
                MentionPicker(
                    suggestions: filteredSuggestions,
                    selectedIndex: pickerSelectedIndex,
                    onSelect: commitMention,
                    onHover: { pickerSelectedIndex = $0 }
                )
                .fixedSize()
                .offset(y: -estimatedPickerHeight - 6)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity)
                )
                .zIndex(1)
            }
        }
        .onChange(of: mentionQuery) { _, _ in
            // Fresh query → reset highlight to the top result so the
            // first arrow keypress moves predictably from index 0.
            pickerSelectedIndex = 0
        }
        .onChange(of: filteredSuggestions) { _, suggestions in
            // Senders snapshot changed under us — clamp selection so
            // it doesn't index out of range.
            if pickerSelectedIndex >= suggestions.count {
                pickerSelectedIndex = max(0, suggestions.count - 1)
            }
        }
    }

    // MARK: - Mention helpers

    /// Suggestions are handles ("Mehdi" rather than "Mehdi Khaledi")
    /// when a sender's first word is unique among the room. Picker
    /// rows display these handles directly; committing one inserts
    /// `@<handle> ` at the caret. The send-time resolver then maps
    /// the body's `@<handle>` back to the canonical full name for
    /// the wire `mentions` array.
    private var filteredSuggestions: [String] {
        guard let query = mentionQuery else { return [] }
        let me = store.displayName
        let lowered = query.lowercased()
        let handleMap = MentionResolver.handles(for: knownSenders)
        return knownSenders
            .filter { $0 != me }
            .compactMap { handleMap[$0] }
            .filter { $0.lowercased().hasPrefix(lowered) }
    }

    private var estimatedPickerHeight: CGFloat {
        // Each row is ~28pt content + padding; container has 8pt
        // padding top/bottom. Used to offset the floating overlay so
        // it sits above the input without overlapping it.
        CGFloat(filteredSuggestions.count) * 30 + 12
    }

    private func handleReturnSend() {
        sendPulse.toggle()
        onSend()
    }

    private func navigatePicker(_ delta: Int) {
        let count = filteredSuggestions.count
        guard count > 0 else { return }
        let next = (pickerSelectedIndex + delta + count) % count
        pickerSelectedIndex = next
    }

    private func commitPickerSelection() {
        let suggestions = filteredSuggestions
        guard !suggestions.isEmpty else { return }
        let idx = max(0, min(pickerSelectedIndex, suggestions.count - 1))
        commitMention(suggestions[idx])
    }

    private func commitMention(_ name: String) {
        mentionController.commit(name)
        pickerSelectedIndex = 0
        // The wrapper clears `mentionQuery` itself after the textual
        // replacement; no need to do it here.
    }

    private func dismissPicker() {
        // Don't mutate the buffer — Esc just hides the picker. The
        // user can keep typing and the picker re-appears once the
        // query becomes ambiguous again.
        mentionQuery = nil
        pickerSelectedIndex = 0
    }

    private var attachButton: some View {
        Button {
            showFileImporter = true
        } label: {
            Image(systemName: "photo")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(imageDraft == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach image")
        .help("Attach image (or drop / paste an image into the composer)")
    }

    private var sendButton: some View {
        Button {
            sendPulse.toggle()
            onSend()
        } label: {
            ZStack {
                // Tinted pulse: a Circle behind the icon that scales
                // up and fades on each `sendPulseTick` bump. Driven by
                // a `.keyframeAnimator` so it plays exactly once per
                // tick and resets — no state to manage in ChatView,
                // no cross-view machinery, no scroll-perf footprint.
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .keyframeAnimator(
                        initialValue: PulseFrame.idle,
                        trigger: sendPulseTick
                    ) { content, frame in
                        content
                            .scaleEffect(frame.scale)
                            .opacity(frame.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1.0, duration: 0)
                            SpringKeyframe(2.0, duration: 0.42, spring: .snappy)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0.0, duration: 0)
                            LinearKeyframe(0.85, duration: 0.04)
                            LinearKeyframe(0.0, duration: 0.38)
                        }
                    }
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(
                        hasContent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                    )
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce.up.byLayer, options: .speed(1.6), value: sendPulse)
            }
        }
        .buttonStyle(SendButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send message")
        .help("Send (Return or ⌘↩)")
    }

    /// Keyframe state for the send button's pulse. `scale` punches
    /// from 1.0 → 1.6 while `opacity` blips up then fades — net effect
    /// is a tinted ring that briefly "throws" outward from the icon.
    private struct PulseFrame {
        var scale: CGFloat
        var opacity: Double
        static let idle = PulseFrame(scale: 1.0, opacity: 0.0)
    }

    /// The 60-tall preview chip that appears above the text field when
    /// the user has attached an image. Decodes the prepared JPEG bytes
    /// back to NSImage for the thumbnail — cheap at chip resolution,
    /// avoids carrying a separate thumbnail through the type system.
    private func imagePreviewChip(_ draft: ImagePipeline.Prepared) -> some View {
        HStack(spacing: 10) {
            Group {
                if let nsImage = NSImage(data: draft.bytes) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Image attached")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("\(draft.width)×\(draft.height) · \(formattedBytes(draft.bytes.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button {
                imageDraft = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attached image")
            .help("Remove attachment")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
    }

    private func replyBanner(_ target: CachedMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.tint)
                .font(.callout)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(target.sender.isEmpty ? "—" : target.sender)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(target.kind == .weird ? "weird message" : target.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
            .help("Cancel reply")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10))
    }

    // MARK: - Image input handlers

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Sandbox: file importer URLs are pre-authorized for read.
            // No security-scoped resource bookkeeping needed because
            // we're synchronously reading them on the main thread.
            onLoadURL(url)
        case .failure(let error):
            onPickError(error)
        }
    }

    private func formattedBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(count))
    }
}

/// Press feedback for the send button — `ButtonStyle.Configuration`
/// exposes `isPressed` directly, which is the right way to wire press
/// visuals without fighting the Button's own tap-handling.
private struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(
                configuration.isPressed
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.28, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

/// Horizontal shake. The `shakes` value is a CGFloat that the parent
/// increments each time it wants the view to rattle (typically on a
/// failed send). When the value changes from N to N+1, SwiftUI
/// interpolates `animatableData` 0→1 over the animation duration, and
/// `effectValue` produces three full sine oscillations across that
/// range — the same shape as macOS's incorrect-password shake.
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let amplitude: CGFloat = 6
        let oscillations: CGFloat = 3
        let translation = amplitude * sin(shakes * .pi * 2 * oscillations)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

