import SwiftUI
import CinemacoreCore

/// One title: art, metadata, cast, and the episode tree for a series.
struct DetailScreen: View {
    let app: AppModel
    let subject: Subject

    @State private var model: DetailViewModel
    @State private var isInWatchlist = false
    @State private var showsEpisodePicker = false
    @State private var downloadNotice: String?
    /// The source generation this screen's view model was built against.
    ///
    /// A detail page opened from a search result or a rail outlives a provider
    /// switch, and its view model captured the old repository in `init`. Left
    /// alone it keeps loading from a source the app is no longer using — which
    /// is one of the ways a switch looked like "the app needs restarting".
    @State private var builtGeneration: Int
    @Environment(\.theme) private var theme

    init(subject: Subject, app: AppModel, season: Int? = nil) {
        self.subject = subject
        self.app = app
        _model = State(
            initialValue: DetailViewModel(subject: subject, repository: app.repository, season: season)
        )
        _builtGeneration = State(initialValue: app.repositoryGeneration)
    }

    private var playback: PlaybackRequest {
        PlaybackRequest(
            subject: subject,
            season: model.isSeries ? model.selectedSeason : nil,
            episode: model.selectedEpisode,
            resourceId: model.selectedLanguage?.resourceId
        )
    }

    /// Built from the row's own episode so the destination cannot pick up a
    /// stale selection when the tap and `selectEpisode` land in the same tick.
    private func playbackRequest(for episode: Episode) -> PlaybackRequest {
        PlaybackRequest(
            subject: subject,
            season: episode.season,
            episode: episode,
            resourceId: model.selectedLanguage?.resourceId
        )
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            StateView(
                state: model.state,
                emptyTitle: "Nothing to show",
                emptyMessage: "This title has no details yet.",
                emptyIcon: "film",
                retry: { await model.load() }
            ) { detail in
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.spacing5) {
                        hero(detail.subject)
                        actions(detail.subject)
                        metadata(detail.subject)

                        if let synopsis = detail.subject.synopsis, !synopsis.isEmpty {
                            Text(synopsis)
                                .font(Typography.body)
                                .foregroundStyle(theme.textSecondary.color)
                                .padding(.horizontal, Layout.spacing4)
                        }

                        if !detail.subject.cast.isEmpty {
                            castRow(detail.subject.cast)
                        }

                        if model.isSeries, !detail.seasons.isEmpty {
                            episodeSection
                        }
                    }
                    .padding(.bottom, Layout.spacing8)
                }
            }
        }
        .navigationTitle(subject.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { isInWatchlist = await app.toggleWatchlist(subject) }
                } label: {
                    Image(systemName: isInWatchlist ? "bookmark.fill" : "bookmark")
                }
                .tint(theme.brand.color)
                .accessibilityLabel(isInWatchlist ? "Remove from watchlist" : "Add to watchlist")
            }
        }
        .task {
            isInWatchlist = app.isInWatchlist(subject.id)
            await model.load()
        }
        // A source switch replaces the catalogue underneath this page. Rebuilding
        // the view model against the new repository (and reloading) is what keeps
        // the page honest instead of showing the previous provider's episode tree.
        .onChange(of: app.repositoryGeneration) { _, generation in
            guard generation != builtGeneration else { return }
            builtGeneration = generation
            model = DetailViewModel(
                subject: subject,
                repository: app.repository,
                season: model.selectedSeason
            )
            Task { await model.load() }
        }
        .sheet(isPresented: $showsEpisodePicker) { episodePicker }
        .alert("Download", isPresented: noticeIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadNotice ?? "")
        }
    }

    // MARK: - Downloads

    /// The downloaded title, resolved once the detail call has the full subject.
    private var downloadSubject: Subject { model.state.value?.subject ?? subject }

    private func startDownload() {
        guard subject.isSeries else {
            Task { await queue([DownloadTarget()]) }
            return
        }
        guard !model.episodes.isEmpty else {
            downloadNotice = "This series has no episodes to download yet."
            return
        }
        showsEpisodePicker = true
    }

    /// The season's episodes, with the whole-season action as the leading row —
    /// `SelectionSheet` already renders exactly that shape for the subtitle
    /// picker, so the picker is reused rather than rebuilt.
    private var episodePicker: some View {
        SelectionSheet(
            title: "Download \(subject.title)",
            items: model.episodes,
            label: { "\($0.number). \($0.displayTitle)" },
            isSelected: { _ in false },
            onSelect: { episode in
                Task { await queue([DownloadTarget(season: episode.season, episode: episode)]) }
            },
            detail: { $0.durationText },
            noneLabel: "Download Season \(model.selectedSeason) · \(model.episodes.count) episodes",
            onSelectNone: {
                Task {
                    await queue(model.episodes.map { DownloadTarget(season: $0.season, episode: $0) })
                }
            }
        )
    }

    private func queue(_ targets: [DownloadTarget]) async {
        showsEpisodePicker = false
        downloadNotice = await app.enqueueDownload(subject: downloadSubject, targets: targets).message
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { downloadNotice != nil },
            set: { if !$0 { downloadNotice = nil } }
        )
    }

    // MARK: - Sections

    private func hero(_ subject: Subject) -> some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: subject.posterURL)
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(BrandGradient.heroScrim(for: theme))

            Text(subject.title)
                .font(Typography.screenTitle)
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Layout.spacing4)
                .padding(.bottom, Layout.spacing3)
        }
        .frame(height: 320)
    }

    private func actions(_ subject: Subject) -> some View {
        HStack(spacing: Layout.spacing3) {
            NavigationLink(value: Route.player(playback)) {
                Label(
                    subject.isSeries && model.selectedEpisode != nil ? "Play Episode" : "Play",
                    systemImage: "play.fill"
                )
                .font(Typography.button)
                .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
            }
            .glassButton(prominent: true)

            Button {
                startDownload()
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(Typography.button)
                    .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
            }
            .glassButton()

            if subject.isSeries, let episode = model.selectedEpisode {
                Text("S\(episode.season) E\(episode.number)")
                    .font(Typography.metadata)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(.horizontal, Layout.spacing4)
    }

    @ViewBuilder
    private func metadata(_ subject: Subject) -> some View {
        let chips = subject.genres + subject.dubs
        if !chips.isEmpty || subject.yearText != nil || subject.durationText != nil {
            ScrollView(.horizontal) {
                HStack(spacing: Layout.spacing2) {
                    if let year = subject.yearText { Chip(text: year) }
                    if let duration = subject.durationText { Chip(text: duration) }
                    ForEach(chips, id: \.self) { Chip(text: $0) }
                }
                .padding(.horizontal, Layout.spacing4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func castRow(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacing3) {
            Text("Cast")
                .font(Typography.sectionTitle)
                .foregroundStyle(theme.textPrimary.color)
                .padding(.horizontal, Layout.spacing4)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Layout.spacing4) {
                    ForEach(cast) { member in
                        VStack(spacing: 6) {
                            RemoteImage(url: member.avatarURL)
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(theme.separator.color, lineWidth: 0.5))
                            Text(member.name)
                                .font(Typography.metadata.weight(.medium))
                                .foregroundStyle(theme.textPrimary.color)
                                .lineLimit(2)
                            if !member.role.isEmpty {
                                Text(member.role)
                                    .font(Typography.badge)
                                    .foregroundStyle(theme.textSecondary.color)
                                    .lineLimit(2)
                            }
                        }
                        .frame(width: 84)
                    }
                }
                .padding(.horizontal, Layout.spacing4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: Layout.spacing3) {
            HStack {
                Text("Episodes")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer()
                if model.seasons.count > 1 {
                    Menu {
                        ForEach(model.seasons) { season in
                            Button(season.title) { model.selectSeason(season.number) }
                        }
                    } label: {
                        Label("Season \(model.selectedSeason)", systemImage: "chevron.up.chevron.down")
                            .font(Typography.metadata)
                    }
                    .tint(theme.brand.color)
                }
            }
            .padding(.horizontal, Layout.spacing4)

            ForEach(model.episodes) { episode in
                episodeRow(episode)
            }
        }
    }

    /// One episode: play it, or download just it.
    ///
    /// The download control is a sibling of the `NavigationLink`, not a child.
    /// A button nested inside a link hands its tap to the link on iOS, so the
    /// old "download this episode" affordance — which only existed as a
    /// whole-season sheet — became the only way to get one episode. Splitting
    /// the row gives each action its own 44 pt target and makes the per-episode
    /// icon possible.
    private func episodeRow(_ episode: Episode) -> some View {
        HStack(spacing: Layout.spacing2) {
            NavigationLink(value: Route.player(playbackRequest(for: episode))) {
                HStack(spacing: Layout.spacing3) {
                    RemoteImage(url: episode.stillURL)
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(episode.number). \(episode.displayTitle)")
                            .font(Typography.rowTitle)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(2)
                        if let duration = episode.durationText {
                            Text(duration)
                                .font(Typography.metadata)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    Spacer(minLength: 0)

                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.background.color)
                        .frame(width: 28, height: 28)
                        .background(theme.brand.color, in: Circle())
                        .accessibilityHidden(true)

                    if model.selectedEpisode?.id == episode.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.brand.color)
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: Layout.minimumTarget)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { model.selectEpisode(episode) })
            .accessibilityHint("Plays this episode")

            episodeDownloadButton(episode)
        }
        .padding(.horizontal, Layout.spacing4)
    }

    /// What the queue already knows about this episode, so the icon can show it
    /// rather than offering a download the viewer already has.
    private func downloadState(for episode: Episode) -> DownloadStatus? {
        let matches = app.downloads.filter {
            $0.subjectID == subject.id
                && $0.season == episode.season
                && $0.episode == episode.number
        }
        // A finished copy outranks one still in flight: it is the state the
        // viewer cares about. Ranking lives here rather than reusing the core's
        // presentation order, which is internal to that module.
        if matches.contains(where: { $0.status == .completed }) { return .completed }
        for status in [DownloadStatus.downloading, .queued, .paused, .failed]
        where matches.contains(where: { $0.status == status }) {
            return status
        }
        return nil
    }

    private func episodeDownloadButton(_ episode: Episode) -> some View {
        let status = downloadState(for: episode)
        let symbol: String = switch status {
        case .completed: "arrow.down.circle.fill"
        case .queued, .downloading, .paused: "arrow.down.circle.dotted"
        case .failed: "arrow.down.circle"
        case nil: "arrow.down.circle"
        }
        return Button {
            Task { await queue([DownloadTarget(season: episode.season, episode: episode)]) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(status == .completed ? theme.brand.color : theme.textPrimary.color)
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
        }
        .buttonStyle(.plain)
        .disabled(status == .completed || status == .queued || status == .downloading)
        .opacity(status == .completed ? 1 : 0.9)
        .accessibilityLabel(
            status == .completed
                ? "Episode \(episode.number) is downloaded"
                : "Download episode \(episode.number)"
        )
        .accessibilityHint("Queues this episode for offline playback")
    }
}
