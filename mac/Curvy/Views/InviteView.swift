import SwiftUI

/// Sole onboarding screen. The user pastes a base64 invite bundle that
/// kumamaki minted with `scripts/mint-invite.sh` and shared over
/// Signal. `SessionStore.applyInvite` decodes, validates against
/// GitHub, persists, and advances `phase`.
struct InviteView: View {
    @Environment(SessionStore.self) private var session
    @State private var paste: String = ""
    @FocusState private var pasteFieldFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arc.and.curve.right")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Curvy")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("place of the curvedz")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Text("Paste your invite")
                    .font(.headline)
                Text("your bro sent you a base64 string. Drop it in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextEditor(text: $paste)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 460, minHeight: 96, maxHeight: 140)
                .padding(12)
                .glassyBackground(in: .rect(cornerRadius: 14))
                .focused($pasteFieldFocused)

            Button {
                Task { await session.applyInvite(paste) }
            } label: {
                Text(isValidating ? "Checking with GitHub…" : "Unlock the room")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(minWidth: 260)
                    .padding(.vertical, 2)
            }
            .adaptiveGlassProminent()
            .tint(Color.curvyInk)
            .controlSize(.extraLarge)
            .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)

            Spacer()
        }
        .padding(32)
        .onAppear { pasteFieldFocused = true }
    }

    private var isValidating: Bool {
        session.phase == .validating
    }
}
