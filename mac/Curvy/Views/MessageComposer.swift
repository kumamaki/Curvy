import SwiftUI

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
struct MessageComposer: View {
    @Binding var draftText: String
    @Binding var replyingTo: CachedMessage?
    let shakeTrigger: Int
    let onSend: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sendPulse: Bool = false
    @State private var didFocusOnce: Bool = false

    private var trimmed: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            composerRow
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .modifier(ShakeEffect(shakes: CGFloat(shakeTrigger)))
        .animation(
            reduceMotion ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.82),
            value: replyingTo?.id
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
            TextField("Message", text: $draftText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit {
                    sendPulse.toggle()
                    onSend()
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

    private var sendButton: some View {
        Button {
            sendPulse.toggle()
            onSend()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(
                    trimmed.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint)
                )
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce.up.byLayer, options: .speed(1.6), value: sendPulse)
        }
        .buttonStyle(SendButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send message")
        .help("Send (Return or ⌘↩)")
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

