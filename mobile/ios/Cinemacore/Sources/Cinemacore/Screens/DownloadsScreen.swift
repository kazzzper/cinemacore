import CinemacoreCore
import SwiftUI

/// The download library: one row per title, the queue's health, and its cost.
///
/// A series is a title, not a list of files. Its episodes live behind the show
/// row on ``DownloadShowScreen``, the way a streaming service opens a show
/// before an episode. The library itself is never grouped into headings —
/// sorting is a menu, not a set of sections.
struct DownloadsScreen: View {
    let app: AppModel

    @State private var model: DownloadsModel
    @State private var pendingAction: PendingDownloadAction?
    @State private var confirmsRemoveCompleted = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: DownloadsModel(app: app))
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            VStack(spacing: 0) {
                if !app.isLive { demoNotice }
                if !app.downloads.isEmpty { summaryBar }

                StateView(
                    state: model.state(app.downloads),
                    emptyTitle: "No downloads yet",
                    emptyMessage: emptyMessage,
                    emptyIcon: "arrow.down.circle",
                    retry: { await model.load() }
                ) { rows in
                    library(rows)
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .task { await model.load() }
        .onChange(of: app.downloads) { _, items in model.note(items) }
        .refreshable { await model.load() }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: pendingConfirmation,
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(pendingAction.kind.confirmLabel, role: .destructive) {
                    switch pendingAction.kind {
                    case .cancel: perform(.cancel, on: pendingAction.ids)
                    case .remove: perform(.remove, on: pendingAction.ids)
                    }
                    self.pendingAction = nil
                }
            }
        } message: {
            Text(pendingAction?.message ?? "")
        }
        .confirmationDialog(
            "Remove completed downloads?",
            isPresented: $confirmsRemoveCompleted,
            titleVisibility: .visible
        ) {
            Button("Remove Completed", role: .destructive) {
                Task { await app.removeCompleted() }
            }
        } message: {
            Text("The downloaded files are deleted from this device. This cannot be undone.")
        }
    }

    /// The demo catalog's streams cannot be fetched at all, so saying so before
    /// the user queues work is kinder than letting every item fail in turn.
    private var demoNotice: some View {
        NoticeBanner(
            text: "Demo catalog: .test streams cannot be fetched, so downloads fail. "
                + "Connect a gateway in Settings."
        )
    }

    private var emptyMessage: String {
        "Open a title from Home, Search or your Watchlist and tap Download. "
            + "Episodes and whole seasons can be queued from a series' detail screen."
    }

    // MARK: - Library

    private func library(_ rows: [DownloadsModel.TitleRow]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.spacing3) {
                ForEach(rows) { row in
                    titleRow(row)
                }
            }
            .padding(.vertical, Layout.spacing3)
        }
    }

    @ViewBuilder
    private func titleRow(_ row: DownloadsModel.TitleRow) -> some View {
        if row.isSeries {
            NavigationLink {
                DownloadShowScreen(app: app, model: model, subjectID: row.subjectID)
            } label: {
                titleRowContent(row, accessory: .chevron)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the downloaded seasons and episodes")
            .contextMenu { rowMenu(row) }
        } else if let item = row.playable, canPlay(item) {
            NavigationLink(value: Route.player(playbackRequest(for: item))) {
                titleRowContent(row, accessory: .play)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays \(row.title)")
            .contextMenu { rowMenu(row) }
        } else {
            Button {
                movieAction(row)
            } label: {
                titleRowContent(row, accessory: accessory(for: row))
            }
            .buttonStyle(.plain)
            .accessibilityHint(movieHint(for: row))
            .contextMenu { rowMenu(row) }
        }
    }

    private func titleRowContent(
        _ row: DownloadsModel.TitleRow,
        accessory: TitleAccessory
    ) -> some View {
        HStack(alignment: .top, spacing: Layout.spacing3) {
            RemoteImage(url: posterURL(row.poster))
                .frame(width: 64, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous))

            VStack(alignment: .leading, spacing: Layout.spacing1) {
                Text(row.title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(2)

                Text(subtitle(for: row))
                    .font(Typography.metadata)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(2)

                if row.status != .completed {
                    HStack(spacing: Layout.spacing2) {
                        statusPill(row.status)
                        if row.status == .downloading || row.status == .paused {
                            ProgressView(value: row.progress)
                                .tint(theme.brand.color)
                                .animation(
                                    reduceMotion ? nil : .linear(duration: 0.25),
                                    value: row.progress
                                )
                            Text("\(Int((row.progress * 100).rounded()))%")
                                .font(Typography.badge)
                                .foregroundStyle(theme.textSecondary.color)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            accessoryView(accessory)
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing2)
        .frame(minHeight: Layout.minimumTarget)
        .contentShape(Rectangle())
    }

    private func subtitle(for row: DownloadsModel.TitleRow) -> String {
        if row.isSeries {
            var text = row.items.count == 1 ? "1 episode" : "\(row.items.count) episodes"
            if row.seasonCount > 1 {
                text = "\(row.seasonCount) seasons · " + text
            }
            text += " · \(row.finishedCount) downloaded"
            if row.failedCount > 0 {
                text += " · \(row.failedCount) failed"
            }
            if row.totalBytes > 0 {
                text += " · \(DownloadsModel.sizeText(row.totalBytes))"
            }
            return text
        }

        var text = row.totalBytes > 0 ? DownloadsModel.sizeText(row.totalBytes) : "Downloaded"
        if row.isFullyDownloaded {
            text += " · Available offline"
        }
        return text
    }

    private func accessory(for row: DownloadsModel.TitleRow) -> TitleAccessory {
        if let item = row.playable, canPlay(item) { return .play }
        if row.failedCount > 0 { return .retry }
        if row.pausedCount > 0 { return .play }
        if row.activeCount > 0 || row.queuedCount > 0 { return .pause }
        return .play
    }

    @ViewBuilder
    private func accessoryView(_ accessory: TitleAccessory) -> some View {
        switch accessory {
        case .chevron:
            Image(systemName: accessory.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
                .accessibilityHidden(true)
        case .play, .pause, .retry:
            Image(systemName: accessory.symbol)
                .font(.body)
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
                .accessibilityHidden(true)
        }
    }

    /// Long-press actions for a whole title, so a row can stay a clean target
    /// instead of carrying a second ellipsis beside its play control.
    @ViewBuilder
    private func rowMenu(_ row: DownloadsModel.TitleRow) -> some View {
        let pausable = row.items.filter { $0.isActive || $0.status == .queued }.map(\.id)
        let resumable = row.items.filter(\.canResume).map(\.id)
        let failed = row.items.filter { $0.status == .failed }.map(\.id)
        let all = row.items.map(\.id)

        if !pausable.isEmpty {
            Button { perform(.pause, on: pausable) } label: {
                Label(row.isSeries ? "Pause Show" : "Pause", systemImage: "pause")
            }
        }
        if !resumable.isEmpty {
            Button { perform(.resume, on: resumable) } label: {
                Label(row.isSeries ? "Resume Show" : "Resume", systemImage: "play")
            }
        }
        if !failed.isEmpty {
            Button {
                Task {
                    for id in failed { await app.retry(id) }
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        Button(role: .destructive) {
            ask(.remove, ids: all, name: row.title, isShow: row.isSeries)
        } label: {
            Label(row.isSeries ? "Remove Show" : "Remove", systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { sortMenu }
        ToolbarItem(placement: .topBarTrailing) { bulkMenu }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: sortKeyBinding) {
                ForEach(DownloadSortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            Button {
                Task { await model.setAscending(!app.settings.downloadSortAscending) }
            } label: {
                Label(
                    app.settings.downloadSortAscending ? "Sort Descending" : "Sort Ascending",
                    systemImage: app.settings.downloadSortAscending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            icon("arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort downloads")
    }

    private var bulkMenu: some View {
        Menu {
            Button { Task { await app.pauseAll() } } label: { Label("Pause All", systemImage: "pause") }
                .disabled(!hasUnfinished)
            Button { Task { await app.resumeAll() } } label: { Label("Resume All", systemImage: "play") }
                .disabled(!hasResumable)
            Divider()
            Button(role: .destructive) {
                confirmsRemoveCompleted = true
            } label: {
                Label("Remove Completed", systemImage: "trash")
            }
            .disabled(completedCount == 0)
        } label: {
            icon("ellipsis.circle")
        }
        .accessibilityLabel("Download actions")
    }

    // MARK: - Summary

    /// The queue at a glance: what is running, what is waiting, and what the
    /// downloads cost. It sits above the library because the storage line used
    /// to be a footer, which on a long queue is the number you had to scroll
    /// furthest to find.
    private var summaryBar: some View {
        let active = app.downloads.filter(\.isActive).count
        let queued = app.downloads.filter { $0.status == .queued }.count
        let onDisk = DownloadsModel.sizeText(model.bytesOnDisk)
        return HStack(spacing: Layout.spacing3) {
            countStat(active, icon: "arrow.down.circle.fill", tint: theme.brand.color)
            countStat(queued, icon: "clock", tint: theme.textSecondary.color)
            countStat(completedCount, icon: "checkmark.circle.fill", tint: .green)
            Spacer(minLength: Layout.spacing2)
            Text("\(onDisk) on disk")
                .font(Typography.metadata)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing2)
        .background(theme.surface.color(opacity: 0.6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(active) downloading, \(queued) queued, \(completedCount) completed, "
                + "\(onDisk) on disk"
        )
    }

    private func countStat(_ count: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
            Text("\(count)")
                .font(Typography.badge)
                .foregroundStyle(theme.textPrimary.color)
                .monospacedDigit()
        }
        .opacity(count == 0 ? 0.45 : 1)
    }

    // MARK: - Controls

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

    private var pendingConfirmation: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private var sortKeyBinding: Binding<DownloadSortKey> {
        Binding(
            get: { app.settings.downloadSortKey },
            set: { value in Task { await model.setSortKey(value) } }
        )
    }

    private var completedCount: Int { app.downloads.filter(\.isFinished).count }
    private var hasUnfinished: Bool {
        app.downloads.contains { $0.status == .downloading || $0.status == .queued }
    }
    private var hasResumable: Bool { app.downloads.contains(where: \.canResume) }

    private func statusColor(_ status: DownloadStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed: theme.accent.color
        case .paused: theme.textSecondary.color
        case .queued, .downloading: theme.brand.color
        }
    }

    // MARK: - Running actions

    private func canPlay(_ item: DownloadItem) -> Bool {
        item.isFinished || app.progressiveReadyIDs.contains(item.id)
    }

    private func movieAction(_ row: DownloadsModel.TitleRow) {
        guard let item = row.playable else { return }
        switch item.status {
        case .failed:
            Task { await app.retry(item.id) }
        case .paused:
            Task { await app.resume(item.id) }
        case .downloading, .queued:
            Task { await app.pause(item.id) }
        case .completed:
            break
        }
    }

    private func movieHint(for row: DownloadsModel.TitleRow) -> String {
        switch accessory(for: row) {
        case .play: "Resume \(row.title)"
        case .pause: "Pause \(row.title)"
        case .retry: "Retry \(row.title)"
        case .chevron: "Open \(row.title)"
        }
    }

    private func perform(_ action: BulkAction, on ids: [String]) {
        Task {
            for id in ids {
                switch action {
                case .pause: await app.pause(id)
                case .resume: await app.resume(id)
                case .cancel: await app.cancel(id)
                case .remove: await app.remove(id)
                }
            }
        }
    }

    private func ask(
        _ kind: PendingDownloadAction.Kind,
        ids: [String],
        name: String,
        isShow: Bool
    ) {
        let message: String
        switch kind {
        case .cancel:
            message = "The partial file for \(name) is deleted. Resuming it starts again from the beginning."
        case .remove:
            message = isShow
                ? "Every episode of \(name) and its downloaded file are deleted. This cannot be undone."
                : "\(name) and its downloaded file are deleted. This cannot be undone."
        }
        pendingAction = PendingDownloadAction(
            kind: kind,
            ids: ids,
            title: kind == .cancel ? "Cancel download?" : isShow ? "Remove show?" : "Remove download?",
            message: message
        )
    }

    private func playbackRequest(for item: DownloadItem) -> PlaybackRequest {
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

/// The trailing glyph on a library row: drill in, or act on a movie.
private enum TitleAccessory {
    case chevron, play, pause, retry

    var symbol: String {
        switch self {
        case .chevron: "chevron.right"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .retry: "arrow.clockwise"
        }
    }
}

/// A queue-wide mutation that touches every id it is given.
private enum BulkAction {
    case pause, resume, cancel, remove
}

/// A destructive per-item or per-show action awaiting confirmation.
private struct PendingDownloadAction: Identifiable {
    enum Kind {
        case cancel
        case remove

        var confirmLabel: String {
            switch self {
            case .cancel: "Cancel Download"
            case .remove: "Remove"
            }
        }
    }

    let kind: Kind
    let ids: [String]
    let title: String
    let message: String

    var id: String { "\(kind)-\(ids.joined(separator: "-"))" }
}
