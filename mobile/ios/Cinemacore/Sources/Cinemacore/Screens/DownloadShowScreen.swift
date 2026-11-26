import CinemacoreCore
import SwiftUI

/// One show's downloads, split by season and then by episode.
///
/// The queue is flat: an episode is a file, not a tree. Grouping by title is
/// where the library shape belongs, so a show opens here instead of dumping
/// every episode it owns onto the Downloads screen.
struct DownloadShowScreen: View {
    let app: AppModel
    let subjectID: String

    @State private var pendingRemoval: DownloadItem?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [DownloadItem] {
        app.downloads.filter { $0.subjectID == subjectID }
    }

    private var title: String { items.first?.title ?? "Downloads" }

    private var seasons: [SeasonGroup] {
        Dictionary(grouping: items) { $0.season ?? 0 }
            .map { season, members in
                SeasonGroup(
                    id: season,
                    title: season == 0 ? "Episodes" : "Season \(season)",
                    items: members.sorted { lhs, rhs in
                        if lhs.episode != rhs.episode { return (lhs.episode ?? 0) < (rhs.episode ?? 0) }
                        return lhs.id < rhs.id
                    }
                )
            }
            .sorted { $0.id < $1.id }
    }

    private var totalBytes: Int64 { items.reduce(into: 0) { $0 += $1.totalBytes } }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            if items.isEmpty {
                ContentUnavailableView(
                    "No downloads for this title",
                    systemImage: "arrow.down.circle",
                    description: Text("It may have been removed. Go back to see the rest of the queue.")
                )
            } else {
                List {
                    Section {
                        header
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }

                    ForEach(seasons) { season in
                        Section(season.title) {
                            ForEach(season.items) { item in
                                row(item)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .confirmationDialog(
            "Remove this download?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { item in
            Button("Remove", role: .destructive) {
                Task { await app.remove(item.id) }
                pendingRemoval = nil
            }
        } message: { item in
            Text("\(displayName(item)) and its downloaded file are deleted. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: Layout.spacing3) {
            RemoteImage(url: posterURL(items.first?.poster))
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous))

            VStack(alignment: .leading, spacing: Layout.spacing1) {
                Text(title)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(theme.textPrimary.color)
                Text(
                    "\(items.count) episode\(items.count == 1 ? "" : "s")"
                        + (totalBytes > 0 ? " · \(DownloadsModel.sizeText(totalBytes))" : "")
                )
                .font(Typography.metadata)
                .foregroundStyle(theme.textSecondary.color)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing3)
    }

    @ViewBuilder
    private func row(_ item: DownloadItem) -> some View {
        HStack(spacing: Layout.spacing3) {
            VStack(alignment: .leading, spacing: Layout.spacing1) {
                HStack(spacing: Layout.spacing2) {
                    if let label = item.episodeLabel {
                        Text(label)
                            .font(Typography.metadata.weight(.medium))
                            .foregroundStyle(theme.textPrimary.color)
                    }
                    Text(item.status.label)
                        .font(Typography.badge)
                        .foregroundStyle(statusColor(item.status))
                }

                if let subtitle = item.episodeTitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.rowTitle)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1)
                }

                if item.status == .failed, let failure = item.failure, !failure.isEmpty {
                    Text(failure)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.brand.color)
                        .lineLimit(2)
                } else if item.status != .completed {
                    ProgressView(value: item.progress)
                        .tint(theme.brand.color)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: item.bytesWritten)
                }

                if let size = item.sizeText {
                    Text(size)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: Layout.spacing1) {
                playOrStatus(item)
                menu(item)
            }
        }
        .padding(.vertical, Layout.spacing1)
        .frame(minHeight: Layout.minimumTarget)
    }

    @ViewBuilder
    private func playOrStatus(_ item: DownloadItem) -> some View {
        if item.isFinished || app.progressiveReadyIDs.contains(item.id) {
            NavigationLink(value: Route.player(playbackRequest(item))) {
                icon("play.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(displayName(item))")
        } else if item.status == .failed {
            Button { Task { await app.retry(item.id) } } label: {
                icon("arrow.clockwise")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry \(displayName(item))")
        } else if item.status == .paused {
            Button { Task { await app.resume(item.id) } } label: {
                icon("play.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume \(displayName(item))")
        } else {
            Button { Task { await app.pause(item.id) } } label: {
                icon("pause.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pause \(displayName(item))")
        }
    }

    private func menu(_ item: DownloadItem) -> some View {
        Menu {
            if item.isActive || item.status == .queued {
                Button { Task { await app.pause(item.id) } } label: { Label("Pause", systemImage: "pause") }
            }
            if item.canResume {
                Button { Task { await app.resume(item.id) } } label: { Label("Resume", systemImage: "play") }
            }
            Divider()
            Button(role: .destructive) {
                pendingRemoval = item
            } label: {
                Label("Remove", systemImage: "trash")
            }
        } label: {
            icon("ellipsis.circle")
        }
        .accessibilityLabel("More actions for \(displayName(item))")
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { Task { await app.resumeAll() } } label: { Label("Resume All", systemImage: "play") }
                Button { Task { await app.pauseAll() } } label: { Label("Pause All", systemImage: "pause") }
                Divider()
                Button(role: .destructive) {
                    Task {
                        for item in items { await app.remove(item.id) }
                    }
                } label: {
                    Label("Remove Show", systemImage: "trash")
                }
            } label: {
                icon("ellipsis.circle")
            }
            .accessibilityLabel("Actions for \(title)")
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(theme.textPrimary.color)
            .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
    }

    private func statusColor(_ status: DownloadStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed: theme.accent.color
        case .paused: theme.textSecondary.color
        case .queued, .downloading: theme.brand.color
        }
    }

    private func displayName(_ item: DownloadItem) -> String {
        guard let label = item.episodeLabel else { return item.title }
        return "\(item.title) · \(label)"
    }

    private func playbackRequest(_ item: DownloadItem) -> PlaybackRequest {
        PlaybackRequest(
            subjectID: item.subjectID,
            title: item.title,
            poster: item.poster,
            season: item.season,
            episode: item.episode
        )
    }

    private func posterURL(_ poster: String?) -> URL? {
        guard let poster, !poster.isEmpty else { return nil }
        return URL(string: poster.hasPrefix("//") ? "https:" + poster : poster)
    }

    private struct SeasonGroup: Identifiable {
        let id: Int
        let title: String
        let items: [DownloadItem]
    }
}
