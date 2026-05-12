import SwiftUI

// macOS 26-only APIs (Liquid Glass + scroll edge effects) are referenced
// against the macOS 26 build SDK but must runtime-gate against the
// macOS 15 deployment target. Every call site for those APIs goes
// through one of the helpers below, so the gating lives in one place
// and the call sites stay one line.
//
// Visual loss on 15 is intentional and accepted: `.thinMaterial` keeps
// shape + translucency just flatter, `.borderedProminent` still picks
// up `.tint(_:)`, and scroll edges revert to a hard cut instead of a
// soft fade.

extension View {
    /// macOS 26+: Liquid Glass over the given shape.
    /// macOS 15:  `.thinMaterial` background, same shape.
    @ViewBuilder
    func glassyBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
        }
    }

    /// Replaces `.buttonStyle(.glassProminent)`. Same call-site contract:
    /// chain `.tint(...)` afterwards if you want a non-default accent.
    /// macOS 26+: `.glassProminent`. macOS 15: `.borderedProminent`.
    @ViewBuilder
    func adaptiveGlassProminent() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Soft fade on both top and bottom edges of a scroll view.
    /// macOS 26+: real `scrollEdgeEffectStyle(.soft, ...)`.
    /// macOS 15:  no-op — falls back to a clean hard edge.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, *) {
            self
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }
}

