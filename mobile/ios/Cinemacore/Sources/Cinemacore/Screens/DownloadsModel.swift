import CinemacoreCore
import Foundation
import Observation

/// Presentation state for ``DownloadsScreen``.
///
/// The queue itself belongs to `DownloadEngine` and the sort choices to
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

    /// One list row, plus whether the show title would repeat the one above it.
    struct Row: Identifiable, Hashable {
        let item: DownloadItem
        let showsSubjectTitle: Bool

        var id: String { item.id }
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

    var sortOrder: DownloadSortOrder {
        DownloadSortOrder(
            key: app.settings.downloadSortKey,
            ascending: app.settings.downloadSortAscending
        )
    }

    var grouping: DownloadGrouping { app.settings.downloadGrouping }

    /// The six-state value `StateView` renders, recomputed from the live queue
    /// on every pass so a progress update cannot lag the list.
    func state(_ items: [DownloadItem]) -> LoadState<[DownloadSection]> {
        switch phase {
        case .loading:
            return .loading
        case .failed(let error):
            return .failed(error)
        case .ready:
            // Sorted first so the order *within* a group is the user's chosen
            // sort whatever the grouping; `grouped` then owns the section order.
            let ordered = DownloadList.sorted(items, by: sortOrder)
            let sections = DownloadList.grouped(ordered, by: grouping, order: sortOrder)
            return sections.contains { !$0.items.isEmpty } ? .loaded(sections) : .empty
        }
    }

    /// The rows of one section. The show title is printed once per run of
    /// episodes from the same subject, so a whole season does not repeat it; a
    /// title-grouped section already carries it in the header.
    func rows(_ section: DownloadSection) -> [Row] {
        var previousSubject: String?
        return section.items.map { item in
            let shows = grouping != .title && item.subjectID != previousSubject
            previousSubject = item.subjectID
            return Row(item: item, showsSubjectTitle: shows)
        }
    }

    /// The measured line under a row: bytes, percentage, and ETA when known.
    ///
    /// A failed row returns `nil` because the failure reason replaces it.
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
            let percent = Int((item.progress * 100).rounded())
            var text = "\(Self.sizeText(item.bytesWritten)) of \(total) · \(percent)%"
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
    /// footer and the rows it sums cannot show two different numbers.
    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .binary)
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

    func setGrouping(_ grouping: DownloadGrouping) async {
        await app.updateSettings { $0.downloadGrouping = grouping }
    }

    private static let storageFailure =
        "Downloads have nowhere to go: the app's data folder is not writable on this device."
}
