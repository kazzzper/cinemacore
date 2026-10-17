import SwiftUI
import CinemacoreCore

// Maps the platform-free Core tokens onto SwiftUI. Core owns the values; this
// file owns their presentation, which keeps the palette testable on Linux.

/// `CinemacoreCore.Section` collides with `SwiftUI.Section` as soon as both are
/// in scope, so rail code names it explicitly.
typealias CatalogSection = CinemacoreCore.Section

extension RGB {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// A translucent variant, for scrims and separators over poster art.
    func color(opacity: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

extension Theme {
    /// The single theme the app renders.
    static let app = Theme.cinematic
}

extension EnvironmentValues {
    /// The one theme in scope for a subtree; the `@Entry` macro replaces the
    /// hand-written key and its get/set pair.
    @Entry var theme: Theme = .cinematic
}

/// Semantic text styles. Built on Dynamic Type styles rather than fixed point
/// sizes, so the whole interface scales with the user's text size.
enum Typography {
    static let screenTitle = Font.largeTitle.weight(.bold)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let rowTitle = Font.headline
    static let cardTitle = Font.subheadline.weight(.semibold)
    static let body = Font.body
    static let metadata = Font.caption
    static let badge = Font.caption2.weight(.bold)
    static let button = Font.body.weight(.semibold)
}

/// Brand gradients reused by posters, the hero, and the splash.
enum BrandGradient {
    static func heroScrim(for theme: Theme) -> LinearGradient {
        LinearGradient(
            colors: [
                theme.background.color(opacity: 0),
                theme.background.color(opacity: 0.55),
                theme.background.color,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func posterPlaceholder(for theme: Theme) -> LinearGradient {
        LinearGradient(
            colors: [theme.surfaceElevated.color, theme.surface.color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The warm bloom behind the splash mark.
    static func glow(for theme: Theme) -> RadialGradient {
        RadialGradient(
            colors: [theme.brandPressed.color(opacity: 0.55), theme.brandPressed.color(opacity: 0)],
            center: .center,
            startRadius: 0,
            endRadius: 260
        )
    }
}

/// A rating pill in the brand's amber.
struct RatingBadge: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(Typography.badge)
            Text(text)
                .font(Typography.badge)
        }
        .foregroundStyle(theme.accent.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(theme.background.color(opacity: 0.72), in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Rated \(text) out of 10")
    }
}

/// A genre / dub / quality chip.
struct Chip: View {
    let text: String
    var prominent = false

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(Typography.metadata.weight(.medium))
            .foregroundStyle(prominent ? theme.background.color : theme.textSecondary.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                prominent ? theme.textPrimary.color(opacity: 0.92) : theme.surfaceElevated.color,
                in: Capsule()
            )
    }
}

/// The brand wordmark, used by the splash and the empty states.
struct Wordmark: View {
    var size: CGFloat = 28

    @Environment(\.theme) private var theme
    /// Lifts the fixed display size onto Dynamic Type; the mark is set in a
    /// display face, so it cannot adopt a text style directly.
    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1

    private var pointSize: CGFloat { size * scale }

    var body: some View {
        Text("CINEMACORE")
            .font(.system(size: pointSize, weight: .heavy, design: .default))
            .kerning(pointSize * 0.16)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(theme.textPrimary.color)
            .accessibilityAddTraits(.isHeader)
    }
}
