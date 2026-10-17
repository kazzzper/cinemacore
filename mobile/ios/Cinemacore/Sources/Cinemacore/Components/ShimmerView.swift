import SwiftUI
import CinemacoreCore

/// A moving sheen for placeholders.
///
/// Disabled under Reduce Motion: the fill becomes a static tint rather than a
/// travelling highlight, which is the correct accommodation.
struct ShimmerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BrandGradient.posterPlaceholder(for: theme)

            if !reduceMotion {
                PhaseAnimator([-1.0, 1.0]) { travel in
                    sheen
                        .visualEffect { content, proxy in
                            content.offset(x: CGFloat(travel) * proxy.size.width * 1.6)
                        }
                } animation: { phase in
                    // Sweep left-to-right, then reset instantly so the highlight
                    // only ever travels one way.
                    phase == 1 ? .linear(duration: 1.25) : .linear(duration: 0)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The band is expressed with gradient stops so it can fill the container
    /// without a `GeometryReader`; `visualEffect` then supplies the travel.
    private var sheen: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: theme.textPrimary.color(opacity: 0), location: 0.2),
                .init(color: theme.textPrimary.color(opacity: 0.10), location: 0.5),
                .init(color: theme.textPrimary.color(opacity: 0), location: 0.8),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// The Home skeleton, shown while the first page loads.
struct HomeSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing6) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Layout.spacing3) {
                        ShimmerView()
                            .frame(width: 160, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .padding(.horizontal, Layout.spacing4)

                        ScrollView(.horizontal) {
                            HStack(spacing: Layout.spacing3) {
                                ForEach(0..<5, id: \.self) { _ in
                                    ShimmerView()
                                        .frame(width: 132, height: 198)
                                        .clipShape(
                                            RoundedRectangle(
                                                cornerRadius: Layout.radiusPoster,
                                                style: .continuous
                                            )
                                        )
                                }
                            }
                            .padding(.horizontal, Layout.spacing4)
                        }
                        .scrollIndicators(.hidden)
                        .disabled(true)
                    }
                }
            }
            .padding(.vertical, Layout.spacing4)
        }
        .accessibilityLabel("Loading")
    }
}

/// A centred progress indicator for full-screen waits.
struct LoadingView: View {
    var message: String = "Loading"

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Layout.spacing4) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.brand.color)
            Text(message)
                .font(Typography.metadata)
                .foregroundStyle(theme.textSecondary.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel(message)
    }
}
