import SwiftUI

/// Top-level router. Switches the visible screen on `SessionStore.phase`.
/// No business logic here — the store does all the work, the view just
/// reads the phase.
struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        ZStack {
            switch session.phase {
            case .bootstrapping, .validating:
                BootstrapView(message: session.phase == .validating ? "Checking with GitHub…" : "Loading…")
            case .needsInvite:
                InviteView()
            case .ready:
                ChatView()
            case .error(let message):
                ErrorView(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
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
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(40)
    }
}
