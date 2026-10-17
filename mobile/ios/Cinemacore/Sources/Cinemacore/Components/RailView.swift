import SwiftUI
import CinemacoreCore

/// A rail's title.
struct RailHeader: View {
    let title: String

    @Environment(\.theme) private var theme

    var body: some View {
        Text(title)
            .font(Typography.sectionTitle)
            .foregroundStyle(theme.textPrimary.color)
            .padding(.horizontal, Layout.spacing4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A horizontally scrolling shelf of titles.
///
/// Navigation is expressed with `NavigationLink(value:)` rather than a callback
/// so no screen has to thread a navigation path through the view tree.
struct RailView: View {
    let section: CatalogSection
    var posterWidth: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing3) {
            RailHeader(title: section.title)

            ScrollView(.horizontal) {
                LazyHStack(spacing: Layout.spacing3) {
                    ForEach(section.items) { subject in
                        NavigationLink(value: Route.detail(subject)) {
                            PosterView(subject: subject, width: posterWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Layout.spacing4)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// The shared grid used by Search, Watchlist and category screens.
struct PosterGrid: View {
    let subjects: [Subject]
    /// When set, every cell carries an explicit remove control (the Watchlist).
    var onRemove: ((Subject) -> Void)?

    @Environment(\.theme) private var theme

    private let columns = [
        GridItem(.adaptive(minimum: Layout.gridMinimum), spacing: Layout.spacing3)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Layout.spacing4) {
            ForEach(subjects) { subject in
                ZStack(alignment: .topTrailing) {
                    NavigationLink(value: Route.detail(subject)) {
                        PosterView(subject: subject)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)

                    if let onRemove {
                        removeControl(subject, action: onRemove)
                    }
                }
            }
        }
        .padding(.horizontal, Layout.spacing4)
    }

    /// The glyph stays chip-sized so the artwork is not covered; the 44pt frame
    /// around it is the tap target.
    private func removeControl(
        _ subject: Subject,
        action: @escaping (Subject) -> Void
    ) -> some View {
        Button {
            action(subject)
        } label: {
            Image(systemName: "bookmark.slash.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.textPrimary.color)
                .padding(6)
                .background(theme.background.color(opacity: 0.66), in: Circle())
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(subject.title) from watchlist")
    }
}
