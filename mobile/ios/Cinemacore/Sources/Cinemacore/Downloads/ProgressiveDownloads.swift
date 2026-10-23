import CinemacoreCore
import Foundation

/// The bridge between the download engine's growing files and a player.
///
/// The engine appends to `.part`; `AVPlayer` cannot read that while it is still
/// being written unless a range-capable HTTP server fronts it. This owns the
/// one loopback server and the registry it reads, and keeps both in step with
/// the queue the rest of the app already observes.
@MainActor
final class ProgressiveDownloads {
    static let shared = ProgressiveDownloads()

    private let root: URL
    private let store = ProgressiveAssetStore()
    private let server: ProgressiveAssetServer
    private var isRunning = false
    /// One prefetch per item id, ever. A failed prefetch is not retried: the
    /// player can still fall back to the CDN, and retrying every progress emit
    /// would turn a metadata probe into a busy loop.
    private var prefetches: [String: Task<Void, Never>] = [:]
    private var attempted: Set<String> = []

    private init(
        root: URL = CinemacoreApp.downloadsDirectory
            .appendingPathComponent(".progressive", isDirectory: true)
    ) {
        self.root = root
        server = ProgressiveAssetServer(store: store)
    }

    /// Binds the loopback port. Safe to call on every appearance; the server
    /// itself makes a second start a no-op.
    func start() async {
        guard !isRunning else { return }
        do {
            try await server.start()
            isRunning = true
        } catch {
            // Without the server an in-progress file simply is not offered;
            // remote playback is still available, so this is not fatal.
            isRunning = false
        }
    }

    /// Stops the server when the app leaves the foreground. Registered assets
    /// are kept: their files and prefetch results are still valid on return.
    func stop() async {
        guard isRunning else { return }
        await server.stop()
        isRunning = false
    }

    /// Mirrors the queue into the store.
    ///
    /// Only direct files that are not finished can grow under the player. A
    /// completed item is deliberately removed: from that moment the completed
    /// download path owns it and the loopback copy would be a second answer to
    /// the same question.
    func sync(
        _ items: [DownloadItem],
        fileURL: (DownloadItem) -> URL,
        partialURL: (DownloadItem) -> URL
    ) async {
        let eligible = items.filter { !$0.isFinished && $0.container.isDirectDownload }
        let eligibleIDs = Set(eligible.map(\.id))
        let stored = await store.all()
        let existing = Dictionary(
            uniqueKeysWithValues: stored.map { ($0.id, $0) }
        )

        for id in Set(existing.keys).subtracting(eligibleIDs) {
            await store.remove(id)
            prefetches.removeValue(forKey: id)?.cancel()
        }

        var assets: [ProgressiveAsset] = []
        assets.reserveCapacity(eligible.count)
        for item in eligible {
            // Preserve metadata a finished prefetch already installed; a later
            // queue emit must not erase the moov location it found.
            let previous = existing[item.id]
            assets.append(ProgressiveAsset(
                id: item.id,
                partialURL: partialURL(item),
                completeURL: fileURL(item),
                totalBytes: item.totalBytes,
                contentType: "video/mp4",
                moovRange: previous?.moovRange,
                moovURL: previous?.moovURL,
                readyThreshold: previous?.readyThreshold ?? Self.defaultThreshold(for: item.totalBytes)
            ))
        }
        await store.register(assets)

        for item in eligible where !attempted.contains(item.id) {
            // Metadata needs a total to prefetch a range out of; an item whose
            // probe has not answered yet waits for the next queue emit.
            guard item.totalBytes > 0 else { continue }
            startPrefetch(for: item)
        }
    }

    /// The loopback URL for an in-progress item, or `nil` before the server has
    /// started (or once the asset has completed).
    func url(for item: DownloadItem) async -> URL? {
        await server.url(for: item.id)
    }

    func isReady(_ item: DownloadItem) async -> Bool {
        await store.isReady(item.id)
    }

    // MARK: - Metadata

    private static func defaultThreshold(for totalBytes: Int64) -> Int64 {
        guard totalBytes > 0 else { return MP4Progressive.defaultReadyBytes }
        return min(totalBytes, MP4Progressive.defaultReadyBytes)
    }

    private func startPrefetch(for item: DownloadItem) {
        guard prefetches[item.id] == nil, !attempted.contains(item.id) else { return }
        attempted.insert(item.id)

        prefetches[item.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.prefetches[item.id] = nil }

            guard let metadata = try? await MP4Progressive.metadata(
                url: item.remoteURL,
                headers: MediaRequest.headers(cookie: item.cookie),
                totalBytes: item.totalBytes,
                cacheDirectory: self.root
            ) else { return }
            guard !Task.isCancelled else { return }

            // The item may have completed or been removed while the probe ran;
            // the store's current entry is the authority on both.
            guard let asset = await self.store.asset(item.id) else { return }
            await self.store.register(ProgressiveAsset(
                id: asset.id,
                partialURL: asset.partialURL,
                completeURL: asset.completeURL,
                totalBytes: asset.totalBytes,
                contentType: asset.contentType,
                moovRange: metadata.moovRange,
                moovURL: metadata.moovURL,
                readyThreshold: metadata.readyThreshold
            ))
        }
    }
}
