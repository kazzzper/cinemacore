import CinemacoreCore
import SwiftUI

/// The download manager: the live queue, its progress, and its storage cost.
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

                StateView(
                    state: model.state(app.downloads),
                    emptyTitle: "No downloads yet",
                    emptyMessage: emptyMessage,
                    emptyIcon: "arrow.down.circle",
                    retry: { await model.load() }
                ) { sections in
                    list(sections)
                }

                if !app.downloads.isEmpty { storageFooter }
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

    // MARK: - List

    private func list(_ sections: [DownloadSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.spacing4) {
                ForEach(sections) { section in
                    if !section.items.isEmpty {
                        VStack(alignment: .leading, spacing: Layout.spacing2) {
                            if model.grouping != .none { sectionHeader(section) }
                            ForEach(model.rows(section)) { row in
                                rowView(row)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Layout.spacing3)
        }
    }

    private func sectionHeader(_ section: DownloadSection) -> some View {
        HStack(spacing: Layout.spacing2) {
            Text(section.title)
                .font(Typography.sectionTitle)
                .foregroundStyle(theme.textPrimary.color)
            Spacer(minLength: 0)
            // A title-grouped section *is* a show, so its whole-show controls
            // live here; other groupings offer them per row instead.
            if model.grouping == .title, let first = section.items.first {
                showMenu(first)
            }
        }
        .padding(.horizontal, Layout.spacing4)
    }

    private func rowView(_ row: DownloadsModel.Row) -> some View {
        let item = row.item
        let showIDs = app.downloads.filter { $0.subjectID == item.subjectID }.map(\.id)
        return HStack(alignment: .top, spacing: Layout.spacing3) {
            RemoteImage(url: posterURL(item.poster))
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous))

            VStack(alignment: .leading, spacing: Layout.spacing1) {
                if row.showsSubjectTitle {
                    Text(item.title)
                        .font(Typography.rowTitle)
                        .foregroundStyle(theme.textPrimary.color)
                        .lineLimit(2)
                }

                HStack(spacing: Layout.spacing2) {
                    if let label = item.episodeLabel {
                        Text(label)
                            .font(Typography.metadata.weight(.medium))
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                    } else if !row.showsSubjectTitle {
                        Text(item.title)
                            .font(Typography.metadata.weight(.medium))
                            .foregroundStyle(theme.textPrimary.color)
                            .lineLimit(1)
                    }
                    Text(item.status.label)
                        .font(Typography.badge)
                        .foregroundStyle(statusColor(item.status))
                }

                if let subtitle = item.episodeTitle, !subtitle.isEmpty, row.showsSubjectTitle {
                    Text(subtitle)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }

                if item.status == .failed, let failure = item.failure, !failure.isEmpty {
                    Text(failure)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.brand.color)
                        .lineLimit(3)
                } else if item.status != .completed {
                    ProgressView(value: item.progress)
                        .tint(theme.brand.color)
                        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: item.bytesWritten)
                        .accessibilityLabel("\(Int((item.progress * 100).rounded())) percent downloaded")
                }

                if let detail = model.detailText(for: item) {
                    Text(detail)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: Layout.spacing1) {
                primaryAction(item)
                itemMenu(item, showIDs: showIDs)
            }
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing2)
        .frame(minHeight: Layout.minimumTarget)
    }

    /// A whole show's controls: every episode of one subject moves together.
    private func showMenu(_ item: DownloadItem) -> some View {
        let ids = app.downloads.filter { $0.subjectID == item.subjectID }.map(\.id)
        return Menu {
            Button { perform(.pause, on: ids) } label: { Label("Pause Show", systemImage: "pause") }
            Button { perform(.resume, on: ids) } label: { Label("Resume Show", systemImage: "play") }
            Divider()
            Button(role: .destructive) {
                ask(.remove, ids: ids, name: item.title)
            } label: {
                Label("Remove Show", systemImage: "trash")
            }
        } label: {
            icon("ellipsis.circle")
        }
        .accessibilityLabel("Actions for \(item.title)")
    }

    private func itemMenu(_ item: DownloadItem, showIDs: [String]) -> some View {
        Menu {
            if item.isActive || item.status == .queued {
                Button { perform(.pause, on: [item.id]) } label: { Label("Pause", systemImage: "pause") }
            }
            if item.status == .failed {
                Button { Task { await app.retry(item.id) } } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            } else if item.canResume {
                Button { perform(.resume, on: [item.id]) } label: { Label("Resume", systemImage: "play") }
            }

            Divider()

            if !item.isFinished {
                Button(role: .destructive) {
                    ask(.cancel, ids: [item.id], name: displayName(item))
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            }
            Button(role: .destructive) {
                ask(.remove, ids: [item.id], name: displayName(item))
            } label: {
                Label("Remove", systemImage: "trash")
            }

            if model.grouping != .title, showIDs.count > 1 {
                Divider()
                Button { perform(.pause, on: showIDs) } label: { Label("Pause Show", systemImage: "pause") }
                Button { perform(.resume, on: showIDs) } label: { Label("Resume Show", systemImage: "play") }
                Button(role: .destructive) {
                    ask(.remove, ids: showIDs, name: item.title)
                } label: {
                    Label("Remove Show", systemImage: "trash")
                }
            }
        } label: {
            icon("ellipsis.circle")
        }
        .accessibilityLabel("More actions for \(displayName(item))")
    }

    @ViewBuilder
    private func primaryAction(_ item: DownloadItem) -> some View {
        if item.isFinished {
            NavigationLink(value: Route.player(playbackRequest(for: item))) {
                icon("play.fill")
            }
            .accessibilityLabel("Play \(displayName(item))")
        } else if item.status == .failed {
            iconButton("arrow.clockwise", label: "Retry \(displayName(item))") {
                Task { await app.retry(item.id) }
            }
        } else if item.status == .paused {
            iconButton("play.fill", label: "Resume \(displayName(item))") {
                perform(.resume, on: [item.id])
            }
        } else {
            iconButton("pause.fill", label: "Pause \(displayName(item))") {
                perform(.pause, on: [item.id])
            }
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
            Divider()
            Picker("Group by", selection: groupingBinding) {
                ForEach(DownloadGrouping.allCases) { grouping in
                    Text(grouping.label).tag(grouping)
                }
            }
        } label: {
            icon("arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort and group downloads")
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

    /// Every completed download's disk cost, plus how many are finished — the
    /// only place a user can see what the feature is costing them.
    private var storageFooter: some View {
        HStack(spacing: Layout.spacing2) {
            Image(systemName: "internaldrive")
            Text("\(DownloadsModel.sizeText(model.bytesOnDisk)) on disk · \(completedCount) completed")
            Spacer(minLength: 0)
        }
        .font(Typography.metadata)
        .foregroundStyle(theme.textSecondary.color)
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing3)
        .background(theme.surface.color(opacity: 0.6))
        .accessibilityElement()
        .accessibilityLabel(
            "Using \(DownloadsModel.sizeText(model.bytesOnDisk)) on disk, \(completedCount) completed"
        )
    }

    // MARK: - Controls

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(theme.textPrimary.color)
            .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
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

    private var groupingBinding: Binding<DownloadGrouping> {
        Binding(
            get: { app.settings.downloadGrouping },
            set: { value in Task { await model.setGrouping(value) } }
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

    private func ask(_ kind: PendingDownloadAction.Kind, ids: [String], name: String) {
        let isShow = ids.count > 1
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

    private func displayName(_ item: DownloadItem) -> String {
        guard let label = item.episodeLabel else { return item.title }
        return "\(item.title) · \(label)"
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
