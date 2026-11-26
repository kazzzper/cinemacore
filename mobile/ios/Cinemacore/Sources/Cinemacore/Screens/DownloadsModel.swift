import CinemacoreCore
import Foundation
import Observation

/// Presentation state for ``DownloadsScreen``.
///
/// The queue itself belongs to `DownloadEngine` and the sort choice to
/// `LibrarySettings`; this only holds what neither can express — the settling
/// phase, the measured disk cost, and the throughput samples behind the ETA.
@MainActor
@Observable
final class DownloadsModel {
    /// Whether the screen has settled into something it can render.
    enum Phase: Sendable {
        case loading
        case ready
        case failed(CinemacoreError)
    }

    /// One title in the download library: a movie's single file or a series'
    /// downloaded episodes, aggregated into the row the library shows.
    struct TitleRow: Identifiable, Sendable {
        let subjectID: String
        let title: String
        let poster: String?
        let items: [DownloadItem]

        var id: String { subjectID }

        var isSeries: Bool { items.contains { $0.season != nil } }
        var seasonCount: Int { Set(items.compactMap(\.season)).count }
        var totalBytes: Int64 { items.reduce(into: Int64(0)) { $0 += $1.totalBytes } }
        var finishedCount: Int { items.filter(\.isFinished).count }
        var activeCount: Int { items.filter(\.isActive).count }
        var queuedCount: Int { items.filter { $0.status == .queued }.count }
        var pausedCount: Int { items.filter { $0.status == .paused }.count }
        var failedCount: Int { items.filter { $0.status == .failed }.count }
        var isFullyDownloaded: Bool { !items.isEmpty && items.allSatisfy(\.isFinished) }

        /// The most urgent state across the title's episodes: something moving
        /// outranks something waiting, which outranks something broken.
        var status: DownloadStatus {
            if activeCount > 0 { return .downloading }
            if queuedCount > 0 { return .queued }
            if failedCount > 0 { return .failed }
            if pausedCount > 0 { return .paused }
            return .completed
        }

        var progress: Double {
            if totalBytes > 0 {
                let written = items.reduce(into: Int64(0)) { $0 += $1.bytesWritten }
                return min(max(Double(written) / Double(totalBytes), 0), 1)
            }
            return items.isEmpty ? 0 : Double(finishedCount) / Double(items.count)
        }

        /// The episode a tap should play, preferring a finished copy.
        var playable: DownloadItem? {
            items.first(where: \.isFinished) ?? items.first
        }
    }

    private(set) var phase: Phase = .loading
    private(set) var bytesOnDisk: Int64 = 0

    private let app: AppModel
    /// Throughput per in-flight item, so the ETA is a measurement, not a guess.
    private var samples: [String: Sample] = [:]

    private struct Sample {
        var bytes: Int64
        var at: Date
        var rate: Double
    }

    init(app: AppModel) {
        self.app = app
    }

    // MARK: - Derived state

    /// The library, one row per title. Grouping is deliberately absent: a
    /// series is a title that opens into its episodes, not a section heading.
    func state(_ items: [DownloadItem]) -> LoadState<[TitleRow]> {
        switch phase {
        case .loading:
            return .loading
        case .failed(let error):
            return .failed(error)
        case .ready:
            let rows = titleRows(items)
            return rows.isEmpty ? .empty : .loaded(rows)
        }
    }

    /// Aggregates the flat queue into titles, ordered by the chosen sort.
    ///
    /// Episodes are kept in transmission order inside a title, because that is
    /// the only order a season reads in; the sort decides between titles.
    func titleRows(_ items: [DownloadItem]) -> [TitleRow] {
        var groups: [String: [DownloadItem]] = [:]
        for item in items {
            groups[item.subjectID, default: []].append(item)
        }
        let rows = groups.compactMap { subjectID, members -> TitleRow? in
            guard let first = members.first else { return nil }
            return TitleRow(
                subjectID: subjectID,
                title: first.title,
                poster: first.poster,
                items: members.sorted(by: episodeOrder)
            )
        }
        let ordered = rows.sorted(by: precedes)
        return app.settings.downloadSortAscending ? ordered : Array(ordered.reversed())
    }

    /// The measured line under an episode row: bytes, percentage, and ETA when
    /// known. A failed row returns `nil` because the failure reason replaces it.
    func detailText(for item: DownloadItem) -> String? {
        switch item.status {
        case .queued:
            return "Waiting to start"
        case .failed:
            return nil
        case .completed:
            return item.sizeText.map { "\($0) · Available offline" }
        case .paused, .downloading:
            guard let total = item.sizeText else { return "Starting…" }
            var text = "\(Self.sizeText(item.bytesWritten)) of \(total)"
            if let eta = etaText(for: item) { text += " · \(eta)" }
            return text
        }
    }

    /// `"4m left"`, or `nil` until two samples make an estimate honest.
    func etaText(for item: DownloadItem) -> String? {
        guard item.isActive, let sample = samples[item.id], sample.rate > 0 else { return nil }
        let seconds = Double(item.remainingBytes) / sample.rate
        guard seconds.isFinite, seconds >= 1 else { return nil }
        if seconds >= 3600 {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return minutes == 0 ? "\(hours)h left" : "\(hours)h \(minutes)m left"
        }
        return seconds >= 60 ? "\(Int(seconds / 60))m left" : "\(Int(seconds.rounded()))s left"
    }

    /// Byte counts on the same 1024-based scale the items use, so the storage
    /// bar and the rows it sums cannot show two different numbers.
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .binary)
    }

    // MARK: - Ordering

    private func precedes(_ lhs: TitleRow, _ rhs: TitleRow) -> Bool {
        switch app.settings.downloadSortKey {
        case .dateAdded:
            let left = lhs.items.map(\.updatedAt).max() ?? .distantPast
            let right = rhs.items.map(\.updatedAt).max() ?? .distantPast
            if left != right { return left < right }
        case .title:
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
        case .size:
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes < rhs.totalBytes }
        case .progress:
            if lhs.progress != rhs.progress { return lhs.progress < rhs.progress }
        case .status:
            let left = statusRank(lhs.status)
            let right = statusRank(rhs.status)
            if left != right { return left < right }
        }
        return lhs.subjectID < rhs.subjectID
    }

    private func episodeOrder(_ lhs: DownloadItem, _ rhs: DownloadItem) -> Bool {
        if lhs.season != rhs.season { return (lhs.season ?? 0) < (rhs.season ?? 0) }
        if lhs.episode != rhs.episode { return (lhs.episode ?? 0) < (rhs.episode ?? 0) }
        return lhs.id < rhs.id
    }

    private func statusRank(_ status: DownloadStatus) -> Int {
        switch status {
        case .downloading: 0
        case .queued: 1
        case .paused: 2
        case .failed: 3
        case .completed: 4
        }
    }

    // MARK: - Load

    /// First appearance, pull-to-refresh, and the error state's retry all land
    /// here, so no path can leave the screen on a spinner.
    func load() async {
        bytesOnDisk = await app.bytesOnDisk()
        guard app.canStoreDownloads() else {
            phase = .failed(.upstream(Self.storageFailure))
            return
        }
        await app.syncDownloads()
        note(app.downloads)
        phase = .ready
    }

    /// Samples the queue after it changes, which is the only time a byte counter
    /// moves. An item that is no longer active loses its estimate on purpose:
    /// a stale rate would produce an ETA for a download that is not running.
    func note(_ items: [DownloadItem]) {
        let now = Date()
        var updated: [String: Sample] = [:]
        for item in items where item.isActive && item.totalBytes > 0 {
            guard let previous = samples[item.id], now > previous.at, item.bytesWritten >= previous.bytes else {
                updated[item.id] = Sample(bytes: item.bytesWritten, at: now, rate: 0)
                continue
            }
            let elapsed = now.timeIntervalSince(previous.at)
            let instant = Double(item.bytesWritten - previous.bytes) / elapsed
            // Weighted, so one jittery flush cannot swing the estimate.
            let rate = previous.rate > 0 ? previous.rate * 0.7 + instant * 0.3 : instant
            updated[item.id] = Sample(bytes: item.bytesWritten, at: now, rate: max(rate, 0))
        }
        samples = updated
    }

    // MARK: - Settings

    func setSortKey(_ key: DownloadSortKey) async {
        await app.updateSettings { $0.downloadSortKey = key }
    }

    func setAscending(_ ascending: Bool) async {
        await app.updateSettings { $0.downloadSortAscending = ascending }
    }

    private static let storageFailure =
        "Downloads have nowhere to go: the app's data folder is not writable on this device."
}
