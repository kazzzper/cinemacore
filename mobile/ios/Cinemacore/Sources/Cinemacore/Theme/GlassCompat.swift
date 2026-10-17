import SwiftUI

// Liquid Glass is iOS 26+. The app deploys to iOS 17, so every glass control
// routes through this modifier and degrades to a system material. Apple's
// guidance is explicit that glass belongs to *chrome* — navigation bars,
// controls, floating overlays — and never to the content layer, so nothing in
// `PosterView` or `RailView` uses it.

private struct GlassButton: ViewModifier {
    var prominent: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        // Branches rather than a ternary: each `buttonStyle` yields a distinct
        // opaque type, so they cannot meet in one `? :` expression.
        if reduceTransparency {
            content.background(.thinMaterial, in: Capsule())
        } else if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// A glass-styled control.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }
}
