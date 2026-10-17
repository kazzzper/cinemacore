import SwiftUI
import Observation
import CinemacoreCore

/// The app's shared state: which catalog is in use, the user's library, and the
/// settings that outlive a launch.
///
/// Deliberately thin — it owns wiring, not behaviour. Per-screen logic lives in
/// the `CinemacoreCore` view models, which are unit-tested on Linux.
@MainActor
@Observable
final class AppModel {
    private(set) var repository: any CatalogRepository
    let library: any LibraryStoring
    private(set) var settings = LibrarySettings()
    /// Human-readable description of where catalog data came from.
    private(set) var sourceNote = ""
    private(set) var bootstrapped = false
    private(set) var watchlistIDs: Set<String> = []
    /// The download queue, mirrored from the engine so SwiftUI can observe a
    /// plain array instead of an `AsyncStream`.
    private(set) var downloads: [DownloadItem] = []
    /// Where downloaded files land. Public so the screen can explain a sandbox
    /// that refuses writes; the engine owns everything inside it.
    let downloadsDirectory: URL
    /// Incremented whenever the catalog source changes.
    ///
    /// Screen view models capture the repository when they are constructed, so
    /// switching gateways has to invalidate them; the root view keys off this.
    private(set) var repositoryGeneration = 0

    /// A gate screen raised from the Lab screen for review.
    ///
    /// These overlays normally appear only when the gateway demands them, which
    /// cannot happen until the provider layer is live.
    var previewGate: GatePreview?

    private let downloadsEngine: DownloadEngine
    /// Cancelled in `deinit`, so observation is not wanted here: nothing renders
    /// the task handle, and the macro would put it behind an accessor that a
    /// non-isolated `deinit` cannot reach.
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(
        repository: any CatalogRepository = FixtureCatalogRepository(),
        library: any LibraryStoring,
        sourceNote: String = "Bundled catalog",
        downloadsDirectory: URL = CinemacoreApp.downloadsDirectory
    ) {
        self.repository = repository
        self.library = library
        self.sourceNote = sourceNote
        self.downloadsDirectory = downloadsDirectory
        self.downloadsEngine = DownloadEngine(
            directory: downloadsDirectory,
            transport: URLSessionDownloadTransport()
        )
    }

    deinit {
        updatesTask?.cancel()
    }

    var isLive: Bool { repository.isLive }

    /// Resolves the catalog, then loads persisted state.
    ///
    /// The gateway probe happens once here rather than per screen so a demo
    /// session is decided (and labelled) exactly once.
    func bootstrap() async {
        guard !bootstrapped else { return }
        settings = await library.settings()

        let configured = settings.gatewayURL ?? LibrarySettings.defaultGatewayURL
        let resolver = CatalogResolver(
            liveURL: URL(string: configured),
            fallback: { FixtureCatalogRepository() }
        )
        let resolution = await resolver.resolve()
        // A cancelled probe reports the gateway as unreachable; committing that
        // would demote a live session to the bundled catalog for a launch already
        // abandoned, so a cancelled bootstrap leaves the source alone.
        //
        // The guard is deliberately scoped to the swap below and not the whole
        // tail: `bootstrapped` gates the entire UI, so returning here without
        // setting it strands the app on a blank background with no way back.
        // The init-time `FixtureCatalogRepository` remains a working fallback.
        if !Task.isCancelled {
            repository = resolution.repository
            sourceNote = resolution.note
            repositoryGeneration += 1
        }

        await refreshWatchlistIDs()
        await startDownloads()
        bootstrapped = true
    }

    /// Starts the engine exactly once per process.
    ///
    /// Re-running `bootstrap()` (a gateway switch) must not reload the queue or
    /// spawn a second observer — the queue is independent of the catalog source.
    private func startDownloads() async {
        guard updatesTask == nil else { return }
        let engine = downloadsEngine
        let stream = await engine.updates()
        updatesTask = Task { [weak self] in
            for await items in stream {
                guard let self else { return }
                self.downloads = items
            }
        }
        // Subscribed before the queue is read, so an item that starts the moment
        // it lands cannot slip past the observer.
        downloads = await engine.load()
        await engine.start()
    }

    /// Points the app at a different gateway and re-resolves.
    func setGatewayURL(_ url: String?) async {
        await updateSettings { $0.gatewayURL = url }
        bootstrapped = false
        await bootstrap()
    }

    /// The live gateway's reported build version, or `nil` when it is not
    /// reachable. `/version` is contract-defined (`contracts/openapi.yaml`).
    func gatewayVersion() async -> String? {
        let configured = settings.gatewayURL ?? LibrarySettings.defaultGatewayURL
        guard let url = URL(string: configured) else { return nil }
        let client = APIClient(baseURL: url, timeout: 4)
        return (try? await client.send(APIRequest(path: "/version"), as: APIClient.Version.self))?
            .version
    }

    // MARK: - Library

    @discardableResult
    func toggleWatchlist(_ subject: Subject) async -> Bool {
        let added = await library.toggleWatchlist(subject)
        await refreshWatchlistIDs()
        return added
    }

    /// Re-reads the cached ids after a watchlist mutation that did not go
    /// through ``toggleWatchlist(_:)``, so the detail screen's bookmark state
    /// cannot disagree with the store.
    func refreshWatchlistIDs() async {
        watchlistIDs = Set(await library.watchlist().map(\.subject.id))
    }

    func isInWatchlist(_ subjectID: String) -> Bool {
        watchlistIDs.contains(subjectID)
    }

    func record(_ point: ResumePoint) async {
        await library.record(point)
    }

    func resumePoint(for id: String) async -> ResumePoint? {
        await library.resumePoint(for: id)
    }

    // MARK: - Settings

    func updateSettings(_ transform: @Sendable (inout LibrarySettings) -> Void) async {
        await library.updateSettings(transform)
        settings = await library.settings()
    }

    // MARK: - Downloads

    /// Re-reads the queue. `updates()` keeps ``downloads`` current; this is the
    /// pull-to-refresh resync for the moment an app returns from suspension.
    func syncDownloads() async {
        downloads = await downloadsEngine.items()
    }

    /// Total bytes every download has cost on disk.
    func bytesOnDisk() async -> Int64 {
        await downloadsEngine.bytesOnDisk()
    }

    /// Where a finished download lives on disk.
    ///
    /// The engine owns the path layout, so the player asks it for the file
    /// rather than rebuilding the name the engine wrote.
    func localFileURL(for item: DownloadItem) -> URL {
        downloadsEngine.fileURL(for: item)
    }

    /// Whether the download directory can be written to.
    ///
    /// The engine cannot report this itself — `enqueue` never throws, so a
    /// sandbox that denies Application Support would silently queue work that
    /// can never run. The screen asks before it offers the feature.
    func canStoreDownloads() -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: downloadsDirectory.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue && manager.isWritableFile(atPath: downloadsDirectory.path)
        }
        return manager.isWritableFile(atPath: downloadsDirectory.deletingLastPathComponent().path)
    }

    func pause(_ id: String) async { await downloadsEngine.pause(id) }
    func resume(_ id: String) async { await downloadsEngine.resume(id) }
    func retry(_ id: String) async { await downloadsEngine.retry(id) }
    func cancel(_ id: String) async { await downloadsEngine.cancel(id) }
    func remove(_ id: String) async { await downloadsEngine.remove(id) }
    func pauseAll() async { await downloadsEngine.pauseAll() }
    func resumeAll() async { await downloadsEngine.resumeAll() }
    func removeCompleted() async { await downloadsEngine.removeCompleted() }

    /// Resolves each target's `PlayInfo` and queues its preferred rendition.
    ///
    /// Failures are counted rather than thrown: eleven of twelve episodes
    /// queued is worth keeping, and the outcome reports the twelfth.
    func enqueueDownload(subject: Subject, targets: [DownloadTarget]) async -> DownloadQueueOutcome {
        var items: [DownloadItem] = []
        var failed = 0
        var reason: String?

        for target in targets {
            do {
                let info = try await repository.playInfo(
                    subjectID: subject.id,
                    season: target.season,
                    episode: target.episode?.number
                )
                guard let stream = info.preferredStream, let url = stream.urlValue else {
                    failed += 1
                    reason = reason ?? "The provider returned no stream for that episode."
                    continue
                }
                items.append(Self.makeItem(subject: subject, target: target, rendition: stream, url: url))
            } catch {
                // Counted rather than thrown so one bad episode cannot discard a
                // season, but the first cause is kept: "You appear to be offline"
                // is worth more than a bare count.
                failed += 1
                reason = reason ?? error.userMessage
            }
        }

        return await enqueue(items, requested: targets.count, failed: failed, reason: reason)
    }

    /// Queues a rendition the caller already holds.
    ///
    /// The player must not re-resolve: the provider serves one URL per title, and
    /// re-fetching could hand the queue a stream the user never selected.
    func enqueueDownload(
        subject: Subject,
        target: DownloadTarget,
        rendition: StreamRendition
    ) async -> DownloadQueueOutcome {
        guard let url = rendition.urlValue else {
            return DownloadQueueOutcome(
                requested: 1,
                added: 0,
                failed: 1,
                failureReason: "That stream's URL is not usable."
            )
        }
        let item = Self.makeItem(subject: subject, target: target, rendition: rendition, url: url)
        return await enqueue([item], requested: 1, failed: 0, reason: nil)
    }

    private func enqueue(
        _ items: [DownloadItem],
        requested: Int,
        failed: Int,
        reason: String?
    ) async -> DownloadQueueOutcome {
        let added = items.isEmpty ? 0 : await downloadsEngine.enqueue(items)
        return DownloadQueueOutcome(
            requested: requested,
            added: added,
            failed: failed,
            failureReason: reason
        )
    }

    private static func makeItem(
        subject: Subject,
        target: DownloadTarget,
        rendition: StreamRendition,
        url: URL
    ) -> DownloadItem {
        let id = downloadID(
            subjectID: subject.id,
            season: target.season,
            episode: target.episode?.number,
            quality: rendition.quality
        )
        return DownloadItem(
            id: id,
            subjectID: subject.id,
            title: subject.title,
            poster: subject.poster,
            season: target.season,
            episode: target.episode?.number,
            episodeTitle: target.episode?.displayTitle,
            quality: rendition.quality,
            remoteURL: url,
            cookie: rendition.cookie,
            status: .queued,
            totalBytes: 0,
            bytesWritten: 0,
            attempts: 0,
            failure: nil,
            createdAt: Date(),
            updatedAt: Date(),
            localFileName: fileName(for: id, url: url)
        )
    }

    /// The engine's stable key: `"<subjectID>-s<S>e<E>-<quality>"`, without the
    /// season/episode pair for a movie.
    private static func downloadID(
        subjectID: String,
        season: Int?,
        episode: Int?,
        quality: String
    ) -> String {
        guard let season, let episode else { return "\(subjectID)-\(quality)" }
        return "\(subjectID)-s\(season)e\(episode)-\(quality)"
    }

    /// The engine renames the partial file to this, so it must be safe on a
    /// filesystem: the provider's quality labels are free-form text.
    private static func fileName(for id: String, url: URL) -> String {
        let stem = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        return "\(stem).\(ext)"
    }
}

/// One episode (or a movie) the user asked to download.
struct DownloadTarget: Hashable, Sendable {
    let season: Int?
    let episode: Episode?

    /// A movie is the target with neither season nor episode.
    init(season: Int? = nil, episode: Episode? = nil) {
        self.season = season
        self.episode = episode
    }
}

/// What one enqueue attempt did, so the UI can report it without guessing.
struct DownloadQueueOutcome: Sendable, Equatable {
    let requested: Int
    let added: Int
    let failed: Int
    /// The first cause behind `failed`, for the case where nothing was queued.
    let failureReason: String?

    /// Already in the queue: `enqueue` skips duplicates by id rather than
    /// replacing them, so a second tap on Download is a no-op.
    var skipped: Int { max(requested - added - failed, 0) }

    /// One line for the confirmation shown after a tap.
    var message: String {
        if requested == 0 { return "Nothing to download." }
        if added == 0 && failed == requested {
            if let failureReason { return failureReason }
            return requested == 1
                ? "No stream was available to download."
                : "No streams were available for those \(requested) episodes."
        }
        var parts: [String] = []
        if added > 0 { parts.append("Queued \(added) \(added == 1 ? "download" : "downloads")") }
        if skipped > 0 { parts.append("\(skipped) already queued") }
        if failed > 0 { parts.append("\(failed) could not be resolved") }
        return parts.joined(separator: " · ") + "."
    }
}
