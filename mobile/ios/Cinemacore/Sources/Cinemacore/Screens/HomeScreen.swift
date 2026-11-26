import SwiftUI
import CinemacoreCore

/// The landing screen: a hero title above a stack of rails.
struct HomeScreen: View {
    let app: AppModel

    @State private var model: HomeViewModel
    /// The source generation `model` was built against, so a switch rebuilds it.
    @State private var builtGeneration: Int
    @Environment(\.theme) private var theme

    /// Compact on purpose: art plus actions stay under 360pt, so a small screen
    /// still shows the first rail without scrolling.
    private let heroArtHeight: CGFloat = 280

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: HomeViewModel(repository: app.repository))
        _builtGeneration = State(initialValue: app.repositoryGeneration)
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
        .refreshable { await app.reloadHistory(); await model.load() }
        .task {
            // Cheap local read: the rail follows a resumed episode without
            // refetching the catalogue.
            await app.reloadHistory()
            await model.loadIfNeeded()
        }
        // A source switch swaps the repository out from under this view model.
        // Rebuilding it here — rather than remounting the whole navigation stack
        // — is what lets the switch happen without losing where the viewer was.
        .onChange(of: app.repositoryGeneration) { _, generation in
            guard generation != builtGeneration else { return }
            builtGeneration = generation
            model = HomeViewModel(repository: app.repository)
            Task { await model.load() }
        }
    }

    @ViewBuilder
    private func rails(_ page: Page) -> some View {
        let sections = model.visibleSections(
            hiding: app.settings.hiddenRails,
            order: app.settings.categoryOrder
        )
        let resume = app.settings.hiddenRails.contains(ContinueWatching.title)
            ? []
            : ContinueWatching.points(from: app.history)
        if sections.isEmpty && resume.isEmpty {
            ContentUnavailableView(
                "Every rail is hidden",
                systemImage: "rectangle.stack.slash",
                description: Text("Turn a rail back on in Settings.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.spacing6) {
                    if !resume.isEmpty {
                        continueWatching(resume)
                    }
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

    /// The app's own Continue Watching rail.
    ///
    /// A resume row has to open the title at the saved position, which a
    /// catalogue rail cannot do — it only carries a subject. It is also the one
    /// home row that cannot disappear with a provider session, because the
    /// points are stored on the device.
    private func continueWatching(_ points: [ResumePoint]) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacing3) {
            RailHeader(title: ContinueWatching.title)

            ScrollView(.horizontal) {
                LazyHStack(spacing: Layout.spacing3) {
                    ForEach(points) { point in
                        NavigationLink(value: Route.player(PlaybackRequest(resume: point))) {
                            VStack(alignment: .leading, spacing: Layout.spacing1) {
                                RemoteImage(url: posterURL(point.poster))
                                    .frame(width: 132, height: 198)
                                    .clipped()
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay(alignment: .bottom) {
                                        ProgressView(value: point.progress)
                                            .tint(theme.brand.color)
                                    }

                                Text(point.title)
                                    .font(Typography.rowTitle)
                                    .foregroundStyle(theme.textPrimary.color)
                                    .lineLimit(1)

                                if let label = point.episodeLabel {
                                    Text(label)
                                        .font(Typography.metadata)
                                        .foregroundStyle(theme.textSecondary.color)
                                } else if let remaining = point.remainingText {
                                    Text(remaining)
                                        .font(Typography.metadata)
                                        .foregroundStyle(theme.textSecondary.color)
                                }
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(resumeLabel(point))
                    }
                }
                .padding(.horizontal, Layout.spacing4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func resumeLabel(_ point: ResumePoint) -> String {
        if let label = point.episodeLabel {
            return "Resume \(point.title), \(label)"
        }
        return "Resume \(point.title)"
    }

    private func posterURL(_ poster: String?) -> URL? {
        guard let poster, !poster.isEmpty else { return nil }
        return URL(string: poster.hasPrefix("//") ? "https:" + poster : poster)
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
