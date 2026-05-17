import SwiftUI

/// Top-level router. Switches the visible screen on `SessionStore.phase`.
/// No business logic here — the store does all the work, the view just
/// reads the phase.
struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(MessageStore.self) private var store
    @Environment(IdentityRegistry.self) private var identityRegistry
    /// Owned here because the lifecycle matches the window. Injected
    /// into descendants via `.environment(...)` so children read it
    /// from the environment rather than being passed a binding from a
    /// distant ancestor — keeps `ConversationSidebar` / `ChatView`
    /// independent of the ownership location.
    @State private var navigation = Navigation()

    var body: some View {
        ZStack {
            switch session.phase {
            case .bootstrapping, .validating:
                BootstrapView(message: session.phase == .validating ? "Checking with GitHub…" : "Loading…")
            case .needsInvite:
                InviteView()
            case .ready:
                ReadyView()
            case .error(let message):
                ErrorView(message: message)
            }
        }
        .environment(navigation)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
        .navigationTitle("Curvy")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}

/// `.ready` layout: NavigationSplitView with the conversation sidebar
/// (collapsed by default) and the active chat as the detail pane.
/// Lives in its own view so `@State` and the per-conversation
/// `openDM` task can scope cleanly without leaking into bootstrap/
/// invite phases that don't need them.
private struct ReadyView: View {
    @Environment(Navigation.self) private var navigation
    @Environment(MessageStore.self) private var store
    @Environment(IdentityRegistry.self) private var identityRegistry
    @Environment(SessionStore.self) private var session
    /// Last DM-open failure for the active conversation, surfaced as
    /// a retry affordance in the detail pane. Cleared on every new
    /// attempt; nil while the open is in-flight or has succeeded.
    @State private var openError: String?

    var body: some View {
        @Bindable var nav = navigation
        NavigationSplitView(columnVisibility: $nav.sidebarVisibility) {
            ConversationSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(minWidth: 480, minHeight: 600)
        }
        .navigationSplitViewStyle(.balanced)
        // Whenever the active conversation flips to a DM that doesn't
        // yet have a poller, spin one up. The result mutates `store.
        // pollers` (Observable), so the detail view re-renders once
        // the poller exists.
        .task(id: navigation.activeConversationID) {
            openError = nil
            await ensureActivePoller()
        }
    }

    @ViewBuilder private var detail: some View {
        if let poller = store.poller(for: navigation.activeConversationID) {
            ChatView(poller: poller, title: title(for: navigation.activeConversationID))
                // Force a fresh ChatView when the conversation flips —
                // `@Query`'s predicate is captured at init time, so
                // reusing the view instance against a new poller would
                // silently keep showing the previous conversation's
                // messages. Re-identifying tears it down + rebuilds.
                .id(poller.conversationID)
        } else if let openError {
            openFailureView(error: openError)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening conversation…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openFailureView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
            Text("Couldn't open this conversation")
                .font(.title3.weight(.semibold))
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Try again") {
                Task {
                    openError = nil
                    await ensureActivePoller()
                }
            }
            .controlSize(.large)
        }
        .padding(40)
    }

    private func title(for conversationID: String) -> String {
        if conversationID == ConversationID.room { return "Curvy" }
        guard let peerID = store.peerUserID(for: conversationID),
              let peer = identityRegistry.lookup(userID: peerID)
        else { return "DM" }
        return peer.displayName
    }

    private func ensureActivePoller() async {
        let convID = navigation.activeConversationID
        if convID == ConversationID.room { return }
        if store.poller(for: convID) != nil { return }
        guard let myUserID = session.myUserID else {
            openError = "Identity not loaded yet — try again in a moment."
            return
        }
        guard let peer = identityRegistry.roster(excluding: myUserID)
            .first(where: { ConversationID.dm(myUserID, $0.userID) == convID })
        else {
            openError = "Peer's identity hasn't been received yet."
            return
        }
        do {
            _ = try await store.openDM(with: peer)
        } catch {
            AppLog.session.error("openDM failed: \(error.localizedDescription, privacy: .public)")
            openError = error.localizedDescription
        }
    }
}

/// Liquid Glass-friendly window background. Three layers, back to
/// front: solid `.background`, a barely-there brand wash, and a tiled
/// film-grain pattern. Grain uses normal compositing (no blend mode)
/// so dark flecks register on light backgrounds and light flecks on
/// dark — works in both appearances without conditional logic.
private struct WindowBackground: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .overlay {
                LinearGradient(
                    colors: [Color.curvyBrand.opacity(0.04), Color.curvyBrandSoft.opacity(0.015)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay {
                GrainOverlay()
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
    }
}

/// Per-pixel film grain rendered directly into SwiftUI's draw tree
/// via `Canvas`. Skipping the NSImage / `NSColor(patternImage:)`
/// route because that bridge silently flattens to a single sampled
/// color in SwiftUI's Metal-backed renderer — pattern semantics
/// don't survive the AppKit→SwiftUI hop.
///
/// Density: roughly one fleck per 14 sq pt. On a 680×720 window
/// that's about 35k 1pt squares — Canvas chews through it without
/// breaking a sweat, and only redraws when the window resizes.
/// The seed is fixed so the grain is the same shape every launch
/// (no shimmer between window resizes).
private struct GrainOverlay: View {
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let count = Int(size.width * size.height / 14)
            var rng = SeededGenerator(seed: 0xCAFE_BABE_F00D_BEEF)
            for _ in 0..<count {
                let x = CGFloat.random(in: 0..<size.width, using: &rng)
                let y = CGFloat.random(in: 0..<size.height, using: &rng)
                let alpha = Double.random(in: 0.18...0.55, using: &rng)
                let isLight = Bool.random(using: &rng)
                let color = Color(white: isLight ? 1.0 : 0.0, opacity: alpha)
                context.fill(
                    Path(CGRect(x: x, y: y, width: 1, height: 1)),
                    with: .color(color)
                )
            }
        }
        .opacity(0.10)
    }
}

/// xorshift64 — small, deterministic, fine for visual noise. Don't
/// use this for anything cryptographic; it's here so the grain pattern
/// is the same every launch instead of reshuffling each time.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEAD_BEEF : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private struct BootstrapView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ErrorView: View {
    let message: String
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text("Something went sideways")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Start over") {
                session.signOut()
            }
            .adaptiveGlassProminent()
            .controlSize(.large)
        }
        .padding(40)
    }
}
