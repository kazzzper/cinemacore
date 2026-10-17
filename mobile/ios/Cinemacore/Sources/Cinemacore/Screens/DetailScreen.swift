import SwiftUI
import CinemacoreCore

/// One title: art, metadata, cast, and the episode tree for a series.
struct DetailScreen: View {
    let app: AppModel
    let subject: Subject

    @State private var model: DetailViewModel
    @State private var isInWatchlist = false
    @Environment(\.theme) private var theme

    init(subject: Subject, app: AppModel) {
        self.subject = subject
        self.app = app
        _model = State(initialValue: DetailViewModel(subject: subject, repository: app.repository))
    }

    private var playback: PlaybackRequest {
        PlaybackRequest(
            subject: subject,
            season: model.isSeries ? model.selectedSeason : nil,
            episode: model.selectedEpisode,
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
                Button {
                    model.selectEpisode(episode)
                } label: {
                    HStack(spacing: Layout.spacing3) {
                        RemoteImage(url: episode.stillURL)
                            .frame(width: 96, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(episode.number). \(episode.displayTitle)")
                                .font(Typography.rowTitle)
                                .foregroundStyle(theme.textPrimary.color)
                                .lineLimit(2)
                            if !episode.duration.isEmpty {
                                Text(episode.duration)
                                    .font(Typography.metadata)
                                    .foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        Spacer(minLength: 0)

                        if model.selectedEpisode?.id == episode.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.brand.color)
                        }
                    }
                    .padding(.horizontal, Layout.spacing4)
                    .frame(minHeight: Layout.minimumTarget)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
