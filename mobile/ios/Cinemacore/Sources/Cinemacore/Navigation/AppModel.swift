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

    init(
        repository: any CatalogRepository = FixtureCatalogRepository(),
        library: any LibraryStoring,
        sourceNote: String = "Bundled catalog"
    ) {
        self.repository = repository
        self.library = library
        self.sourceNote = sourceNote
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
        // abandoned, so a cancelled bootstrap changes nothing.
        if Task.isCancelled { return }
        repository = resolution.repository
        sourceNote = resolution.note
        repositoryGeneration += 1

        await refreshWatchlistIDs()
        bootstrapped = true
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
}
