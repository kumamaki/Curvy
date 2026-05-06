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
    let onSend: () -> Void
    let onPickError: (any Error) -> Void
    let onLoadURL: (URL) -> Void
    let onLoadProviders: ([NSItemProvider]) -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sendPulse: Bool = false
    @State private var didFocusOnce: Bool = false
    @State private var showFileImporter: Bool = false

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
        .onAppear {
            // Fire once per process — `.onAppear` re-fires on window
            // restore from minimize, which would steal focus from
            // wherever the user is typing.
            guard !didFocusOnce else { return }
            didFocusOnce = true
            focused = true
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
        // .onPasteCommand only fires when the pasteboard contains one
        // of the listed UTTypes — text pastes don't trigger this, so
        // the text field still handles ⌘V for typed content. Note we
        // list png/jpeg/tiff/heic explicitly because `.image` is an
        // abstract UTType and some clipboard sources advertise only
        // a concrete subtype.
        .onPasteCommand(of: [.image, .png, .jpeg, .tiff, .heic]) { providers in
            onLoadProviders(providers)
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
        HStack(alignment: .center, spacing: 10) {
            attachButton
            TextField("Message", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit {
                    sendPulse.toggle()
                    onSend()
                }
                // SwiftUI's `TextField(axis: .vertical)` + `.onSubmit`
                // treats every Return press as a submission, even with
                // Shift held — so Shift+Return would otherwise send
                // instead of inserting a newline. Intercept here:
                // append `\n` and swallow the event when shift is
                // held, fall through to `.onSubmit` otherwise.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    draftText.append("\n")
                    return .handled
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                }

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(reduceMotion ? .linear(duration: 0) : .smooth(duration: 0.18), value: draftText)
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
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(
                    hasContent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                )
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce.up.byLayer, options: .speed(1.6), value: sendPulse)
        }
        .buttonStyle(SendButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send message")
        .help("Send (Return or ⌘↩)")
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

