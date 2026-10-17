import SwiftUI
import CinemacoreCore

/// Continue-watching history.
struct HistoryScreen: View {
    let app: AppModel

    @State private var model: HistoryViewModel
    @State private var confirmsClear = false
    @Environment(\.theme) private var theme

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: HistoryViewModel(library: app.library))
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            StateView(
                state: model.state,
                emptyTitle: "Nothing watched yet",
                emptyMessage: "Titles you play appear here so you can resume them.",
                emptyIcon: "clock.arrow.circlepath",
                retry: { await model.load() }
            ) { points in
                ScrollView {
                    LazyVStack(spacing: Layout.spacing3) {
                        ForEach(points) { point in
                            row(point)
                        }
                    }
                    .padding(.horizontal, Layout.spacing4)
                    .padding(.vertical, Layout.spacing3)
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", role: .destructive) { confirmsClear = true }
                    .disabled(model.state.value?.isEmpty ?? true)
            }
        }
        .confirmationDialog(
            "Clear watch history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task { await model.clear() }
            }
        } message: {
            Text("Resume points for every title are removed. This cannot be undone.")
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private func row(_ point: ResumePoint) -> some View {
        HStack(spacing: Layout.spacing3) {
            NavigationLink(value: Route.player(playbackRequest(for: point))) {
                HStack(spacing: Layout.spacing3) {
                    RemoteImage(url: posterURL(point))
                        .frame(width: 72, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: Layout.spacing1) {
                        Text(point.title)
                            .font(Typography.rowTitle)
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(2)
                        if let label = point.episodeLabel {
                            Text(label)
                                .font(Typography.metadata)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                        ProgressView(value: point.progress)
                            .tint(theme.brand.color)
                        if let remaining = point.remainingText {
                            Text(remaining)
                                .font(Typography.badge)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.remove(id: point.id) }
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(point.title) from history")
        }
        .frame(minHeight: Layout.minimumTarget)
    }

    /// Rebuilds the minimal subject a resume needs; the player re-resolves the
    /// full title from the provider, so only the history fields are required.
    private func playbackRequest(for point: ResumePoint) -> PlaybackRequest {
        let subject = Subject(
            id: point.subjectID,
            title: point.title,
            poster: point.poster,
            kind: point.episode != nil ? "series" : "movie"
        )
        let episode = point.season.flatMap { season in
            point.episode.map { number in
                Episode(subjectID: point.subjectID, season: season, number: number)
            }
        }
        return PlaybackRequest(subject: subject, season: point.season, episode: episode)
    }

    private func posterURL(_ point: ResumePoint) -> URL? {
        guard let poster = point.poster, !poster.isEmpty else { return nil }
        return URL(string: poster.hasPrefix("//") ? "https:" + poster : poster)
    }
}
