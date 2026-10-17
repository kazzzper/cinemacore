import SwiftUI
import CinemacoreCore

/// The landing screen: a hero title above a stack of rails.
struct HomeScreen: View {
    let app: AppModel

    @State private var model: HomeViewModel
    @Environment(\.theme) private var theme

    /// Compact on purpose: art plus actions stay under 360pt, so a small screen
    /// still shows the first rail without scrolling.
    private let heroArtHeight: CGFloat = 280

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: HomeViewModel(repository: app.repository))
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            VStack(spacing: 0) {
                if !app.isLive {
                    DemoSourceBanner(note: app.sourceNote, isLive: false)
                }

                StateView(
                    state: model.state,
                    loading: .homeSkeleton,
                    emptyTitle: "No titles yet",
                    emptyMessage: "The catalog came back empty.",
                    emptyIcon: "popcorn",
                    retry: { await model.load() }
                ) { page in
                    rails(page)
                }
            }
        }
        .navigationTitle("Cinemacore")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private func rails(_ page: Page) -> some View {
        let sections = model.visibleSections(hiding: app.settings.hiddenRails)
        if sections.isEmpty {
            ContentUnavailableView(
                "Every rail is hidden",
                systemImage: "rectangle.stack.slash",
                description: Text("Turn a rail back on in Settings.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.spacing6) {
                    if let featured = sections.first?.items.first {
                        hero(featured)
                    }
                    ForEach(sections) { section in
                        RailView(section: section)
                    }
                }
                .padding(.vertical, Layout.spacing4)
            }
        }
    }

    /// The lead title of the first visible rail. Nothing renders when the rail
    /// is empty, so an empty page stays an empty page.
    ///
    /// The actions sit below the artwork rather than on it: glass over artwork
    /// is what `ADR 0003` rules out, and the detail screen's header does the
    /// same.
    private func hero(_ subject: Subject) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacing3) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: subject.posterURL)
                    .frame(height: heroArtHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(BrandGradient.heroScrim(for: theme))

                VStack(alignment: .leading, spacing: Layout.spacing1) {
                    Text(subject.title)
                        .font(Typography.screenTitle)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    if !subject.metadataLine.isEmpty {
                        Text(subject.metadataLine)
                            .font(Typography.metadata)
                            .foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1)
                    }
                }
                .padding(Layout.spacing4)
            }
            .clipShape(RoundedRectangle(cornerRadius: Layout.radiusLarge, style: .continuous))

            HStack(spacing: Layout.spacing2) {
                NavigationLink(value: Route.player(PlaybackRequest(subject: subject))) {
                    Label("Play", systemImage: "play.fill")
                        .font(Typography.button)
                        .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
                }
                .glassButton(prominent: true)

                NavigationLink(value: Route.detail(subject)) {
                    Label("Details", systemImage: "info.circle")
                        .font(Typography.button)
                        .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
                }
                .glassButton()
            }
        }
        .padding(.horizontal, Layout.spacing4)
    }
}
