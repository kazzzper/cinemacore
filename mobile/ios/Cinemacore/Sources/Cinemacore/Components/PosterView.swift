import SwiftUI
import CinemacoreCore

/// Poster / still artwork with a branded placeholder.
///
/// The provider serves some titles without art, and poster URLs can fail
/// offline, so a missing image must still look deliberate rather than broken.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AsyncImage(
            url: url,
            transaction: Transaction(animation: reduceMotion ? nil : .easeIn(duration: 0.18))
        ) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            case .failure:
                placeholder(systemImage: "film")
            case .empty:
                ShimmerView()
            @unknown default:
                placeholder(systemImage: "film")
            }
        }
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            BrandGradient.posterPlaceholder(for: theme)
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(theme.textSecondary.color.opacity(0.6))
        }
    }
}

/// A single title in a rail or grid.
///
/// Content layer: standard materials only, no Liquid Glass.
struct PosterView: View {
    let subject: Subject
    var width: CGFloat = 132
    var showsTitle = true

    @Environment(\.theme) private var theme

    private var height: CGFloat { width / Layout.posterAspectRatio }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: subject.posterURL)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: Layout.radiusPoster, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.radiusPoster, style: .continuous)
                            .strokeBorder(theme.separator.color, lineWidth: 0.5)
                    )

                if let rating = subject.ratingText {
                    RatingBadge(text: rating)
                        .padding(6)
                }
            }

            if showsTitle {
                Text(subject.title)
                    .font(Typography.cardTitle)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)

                if !subject.metadataLine.isEmpty {
                    Text(subject.metadataLine)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = [subject.title]
        if subject.isSeries { parts.append(subject.seasonCount == 1 ? "1 season" : "\(subject.seasonCount) seasons") }
        if let year = subject.yearText { parts.append(year) }
        if let rating = subject.ratingText { parts.append("rated \(rating)") }
        return parts.joined(separator: ", ")
    }
}
