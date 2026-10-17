import SwiftUI
import CinemacoreCore

/// The branded launch moment.
///
/// Starts from the same aperture mark as the Home Screen icon, so the
/// transition from launch to content reads as one continuous brand rather than
/// a system flash followed by an unrelated screen.
struct SplashView: View {
    /// Called when the intro has finished and the caller should reveal content.
    let onFinished: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the keyframes; the animator runs once as this flips on appear.
    @State private var started = false

    private struct Values {
        var markScale: CGFloat = 0.86
        var markOpacity: Double = 0
        var glowOpacity: Double = 0
        var wordmarkOpacity: Double = 0
        var taglineOpacity: Double = 0
    }

    var body: some View {
        if reduceMotion {
            content(Self.finished)
                .task { onFinished() }
        } else {
            KeyframeAnimator(initialValue: Values(), trigger: started) { values in
                content(values)
            } keyframes: { _ in
                KeyframeTrack(\.markScale) {
                    SpringKeyframe(1, duration: 0.7, spring: Spring(response: 0.7, dampingRatio: 0.72))
                }
                KeyframeTrack(\.markOpacity) { LinearKeyframe(1, duration: 0.7) }
                KeyframeTrack(\.glowOpacity) { LinearKeyframe(1, duration: 1.0) }
                KeyframeTrack(\.wordmarkOpacity) {
                    LinearKeyframe(0, duration: 0.7)
                    LinearKeyframe(1, duration: 0.5)
                }
                KeyframeTrack(\.taglineOpacity) {
                    LinearKeyframe(0, duration: 0.88)
                    LinearKeyframe(1, duration: 0.5)
                }
            }
            .task {
                started = true
                try? await Task.sleep(for: .milliseconds(1600))
                onFinished()
            }
        }
    }

    /// The finished frame, used verbatim under Reduce Motion.
    private static let finished = Values(
        markScale: 1, markOpacity: 1, glowOpacity: 1, wordmarkOpacity: 1, taglineOpacity: 1
    )

    private func content(_ values: Values) -> some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            BrandGradient.glow(for: theme)
                .frame(width: 520, height: 520)
                .opacity(values.glowOpacity)
                .blur(radius: 30)
                .ignoresSafeArea()

            VStack(spacing: Layout.spacing5) {
                mark
                    .frame(width: 168, height: 168)
                    .scaleEffect(values.markScale)
                    .opacity(values.markOpacity)

                VStack(spacing: Layout.spacing2) {
                    Wordmark(size: 26)
                        .opacity(values.wordmarkOpacity)

                    Text("Cinema, curated.")
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                        .opacity(values.taglineOpacity)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cinemacore")
    }

    /// The artwork shipped alongside the icon; the glow and wordmark carry the
    /// screen even if the image cannot be resolved.
    private var mark: some View {
        Image("SplashLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .shadow(color: theme.brandPressed.color.opacity(0.35), radius: 24, y: 6)
    }
}
