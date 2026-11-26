import CinemacoreCore
import SwiftUI

/// One show's downloads, split by season.
///
/// The library opens a title here, the way a streaming service opens a show
/// before an episode: the seasons are a selector, the episodes are the list,
/// and each row owns its own play, pause and remove controls.
struct DownloadShowScreen: View {
    let app: AppModel
    let model: DownloadsModel
    let subjectID: String

    @State private var selectedSeason: Int?
    @State private var pendingRemoval: DownloadItem?
    @State private var confirmsRemoveShow = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [DownloadItem] {
        app.downloads.filter { $0.subjectID == subjectID }
    }

    private var title: String { items.first?.title ?? "Downloads" }

    private var seasons: [Int] {
        Array(Set(items.compactMap(\.season))).sorted()
    }

    private var activeSeason: Int? {
        if let selectedSeason, seasons.contains(selectedSeason) { return selectedSeason }
        return seasons.first
    }

    private var visibleItems: [DownloadItem] {
        let filtered: [DownloadItem]
        if let season = activeSeason {
            filtered = items.filter { $0.season == season }
        } else {
            filtered = items
        }
        return filtered.sorted { lhs, rhs in
            if lhs.episode != rhs.episode { return (lhs.episode ?? 0) < (rhs.episode ?? 0) }
            return lhs.id < rhs.id
        }
    }

    private var totalBytes: Int64 { items.reduce(into: 0) { $0 += $1.totalBytes } }
    private var finishedCount: Int { items.filter(\.isFinished).count }

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.spacing3) {
                        header

                        if seasons.count > 1 {
                            seasonPicker
                        }

                        ForEach(visibleItems) { item in
                            row(item)
                        }
                    }
                    .padding(.bottom, Layout.spacing4)
                }
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
        .confirmationDialog(
            "Remove \(title)?",
            isPresented: $confirmsRemoveShow,
            titleVisibility: .visible
        ) {
            Button("Remove Show", role: .destructive) {
                Task {
                    for item in items { await app.remove(item.id) }
                }
            }
        } message: {
            Text("Every downloaded episode of \(title) is deleted. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Layout.spacing3) {
            RemoteImage(url: posterURL(items.first?.poster))
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous))

            VStack(alignment: .leading, spacing: Layout.spacing1) {
                Text(title)
                    .font(Typography.sectionTitle)
                    .foregroundStyle(theme.textPrimary.color)
                Text(
                    "\(items.count) episode\(items.count == 1 ? "" : "s")"
                        + " · \(finishedCount) downloaded"
                        + (totalBytes > 0 ? " · \(DownloadsModel.sizeText(totalBytes))" : "")
                )
                .font(Typography.metadata)
                .foregroundStyle(theme.textSecondary.color)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.top, Layout.spacing3)
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Layout.spacing2) {
                ForEach(seasons, id: \.self) { season in
                    let isSelected = activeSeason == season
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            selectedSeason = season
                        }
                    } label: {
                        Text("Season \(season)")
                            .font(Typography.metadata.weight(.semibold))
                            .foregroundStyle(
                                isSelected ? theme.background.color : theme.textSecondary.color
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? theme.textPrimary.color(opacity: 0.92)
                                    : theme.surfaceElevated.color,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Layout.spacing4)
        }
    }

    private func row(_ item: DownloadItem) -> some View {
        HStack(alignment: .top, spacing: Layout.spacing3) {
            VStack(alignment: .leading, spacing: Layout.spacing1) {
                HStack(spacing: Layout.spacing2) {
                    if let label = item.episodeLabel {
                        Text(label)
                            .font(Typography.metadata.weight(.medium))
                            .foregroundStyle(theme.textPrimary.color)
                    }
                    statusPill(item.status)
                }

                if let subtitle = item.episodeTitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.rowTitle)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                }

                if item.status == .failed, let failure = item.failure, !failure.isEmpty {
                    Text(failure)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.brand.color)
                        .lineLimit(2)
                } else if item.status != .completed {
                    HStack(spacing: Layout.spacing2) {
                        ProgressView(value: item.progress)
                            .tint(theme.brand.color)
                            .animation(
                                reduceMotion ? nil : .linear(duration: 0.25),
                                value: item.bytesWritten
                            )
                        Text("\(Int((item.progress * 100).rounded()))%")
                            .font(Typography.badge)
                            .foregroundStyle(theme.textSecondary.color)
                            .monospacedDigit()
                    }
                }

                if let detail = model.detailText(for: item) {
                    Text(detail)
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
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing2)
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
            if item.status == .failed {
                Button { Task { await app.retry(item.id) } } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
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
                Button {
                    Task {
                        for item in items where item.canResume { await app.resume(item.id) }
                    }
                } label: {
                    Label("Resume Show", systemImage: "play")
                }
                Button {
                    Task {
                        for item in items where item.isActive || item.status == .queued {
                            await app.pause(item.id)
                        }
                    }
                } label: {
                    Label("Pause Show", systemImage: "pause")
                }
                Divider()
                Button(role: .destructive) {
                    confirmsRemoveShow = true
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

    private func statusPill(_ status: DownloadStatus) -> some View {
        Text(status.label)
            .font(Typography.badge)
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.16), in: Capsule())
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
}
