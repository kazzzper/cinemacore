import Testing
import Foundation
@testable import CinemacoreCore

/// A fully scripted `CatalogRepository`: each call returns a configured result
/// or throws a chosen typed error, counts its calls so caching can be proven,
/// and can stall so a test can observe an in-flight state or interleave two
/// requests.
final class MockCatalogRepository: CatalogRepository, @unchecked Sendable {
    /// Guarded by `lock`. `@unchecked Sendable` is the price of a mutable test
    /// double that the protocol's nonisolated methods can reach.
    private struct State: Sendable {
        var sourceName = "Mock catalog"
        var isLive = false
        var delay: Duration = .zero

        var homeResult: Result<Page, CinemacoreError> = .success(Page(sections: []))
        var searchResult: Result<[Subject], CinemacoreError> = .success([])
        var detailResult: Result<Subject, CinemacoreError> =
            .success(Subject(id: "unset", title: "Unset"))
        var seasonsResult: Result<[Season], CinemacoreError> = .success([])
        var playInfoResult: Result<PlayInfo, CinemacoreError> = .success(PlayInfo())
        var suggestionsResult: Result<[String], CinemacoreError> = .success([])

        var homeCallCount = 0
        var searchCallCount = 0
        var detailCallCount = 0
        var seasonsCallCount = 0
        var playInfoCallCount = 0
        var suggestionsCallCount = 0

        var searchQueries: [String] = []
        var suggestionsQueries: [String] = []
        var seasonsQueries: [String] = []
    }

    private let lock = NSLock()
    private var state = State()

    private func read<T: Sendable>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func mutate(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }

    private func stall() async {
        let delay = read { $0.delay }
        guard delay > .zero else { return }
        try? await Task.sleep(for: delay)
    }

    private func unwrap<T: Sendable>(
        _ result: Result<T, CinemacoreError>
    ) throws(CinemacoreError) -> T {
        switch result {
        case .success(let value): value
        case .failure(let error): throw error
        }
    }

    // MARK: - Scripting

    var sourceName: String { read { $0.sourceName } }
    var isLive: Bool { read { $0.isLive } }

    func setDelay(_ delay: Duration) { mutate { $0.delay = delay } }
    func stubHome(_ page: Page) { mutate { $0.homeResult = .success(page) } }
    func failHome(_ error: CinemacoreError) { mutate { $0.homeResult = .failure(error) } }
    func stubSearch(_ subjects: [Subject]) { mutate { $0.searchResult = .success(subjects) } }
    func failSearch(_ error: CinemacoreError) { mutate { $0.searchResult = .failure(error) } }
    func stubSuggestions(_ values: [String]) { mutate { $0.suggestionsResult = .success(values) } }
    func failSuggestions(_ error: CinemacoreError) {
        mutate { $0.suggestionsResult = .failure(error) }
    }
    func stubDetail(_ subject: Subject) { mutate { $0.detailResult = .success(subject) } }
    func failDetail(_ error: CinemacoreError) { mutate { $0.detailResult = .failure(error) } }
    func stubSeasons(_ seasons: [Season]) { mutate { $0.seasonsResult = .success(seasons) } }
    func failSeasons(_ error: CinemacoreError) { mutate { $0.seasonsResult = .failure(error) } }

    var homeCallCount: Int { read { $0.homeCallCount } }
    var searchCallCount: Int { read { $0.searchCallCount } }
    var detailCallCount: Int { read { $0.detailCallCount } }
    var seasonsCallCount: Int { read { $0.seasonsCallCount } }
    var playInfoCallCount: Int { read { $0.playInfoCallCount } }
    var suggestionsCallCount: Int { read { $0.suggestionsCallCount } }
    var searchQueries: [String] { read { $0.searchQueries } }
    var suggestionsQueries: [String] { read { $0.suggestionsQueries } }
    var seasonsQueries: [String] { read { $0.seasonsQueries } }

    // MARK: - CatalogRepository

    func home() async throws(CinemacoreError) -> Page {
        mutate { $0.homeCallCount += 1 }
        let result = read { $0.homeResult }
        await stall()
        return try unwrap(result)
    }

    func search(_ query: String) async throws(CinemacoreError) -> [Subject] {
        mutate {
            $0.searchCallCount += 1
            $0.searchQueries.append(query)
        }
        let result = read { $0.searchResult }
        await stall()
        return try unwrap(result)
    }

    func detail(id: String) async throws(CinemacoreError) -> Subject {
        mutate { $0.detailCallCount += 1 }
        let result = read { $0.detailResult }
        await stall()
        return try unwrap(result)
    }

    func seasons(subjectID: String) async throws(CinemacoreError) -> [Season] {
        mutate {
            $0.seasonsCallCount += 1
            $0.seasonsQueries.append(subjectID)
        }
        let result = read { $0.seasonsResult }
        await stall()
        return try unwrap(result)
    }

    func playInfo(
        subjectID: String,
        season: Int?,
        episode: Int?
    ) async throws(CinemacoreError) -> PlayInfo {
        mutate { $0.playInfoCallCount += 1 }
        let result = read { $0.playInfoResult }
        await stall()
        return try unwrap(result)
    }

    func suggestions(for query: String) async throws(CinemacoreError) -> [String] {
        mutate {
            $0.suggestionsCallCount += 1
            $0.suggestionsQueries.append(query)
        }
        let result = read { $0.suggestionsResult }
        await stall()
        return try unwrap(result)
    }
}

/// Polls for an observable outcome instead of sleeping a fixed span, so the
/// debounce tests assert on state rather than wall-clock precision.
@MainActor
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline {
            Issue.record("timed out waiting for \(description)")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Home

@Suite("HomeViewModel")
@MainActor
struct HomeViewModelTests {

    private func page(_ titles: [String]) -> Page {
        Page(sections: titles.map { Section(title: $0, items: [Subject(id: $0, title: $0)]) })
    }

    @Test("state goes idle -> loading -> loaded and fetches once")
    func idleToLoaded() async {
        let repository = MockCatalogRepository()
        repository.stubHome(page(["Continue Watching", "Trending Now"]))
        // Long enough that `.loading` cannot be missed, short-circuited by
        // cancelling the load task below.
        repository.setDelay(.seconds(30))
        let viewModel = HomeViewModel(repository: repository)

        if case .idle = viewModel.state {} else {
            Issue.record("expected .idle before load, got \(viewModel.state)")
        }

        let load = Task { await viewModel.load() }
        await waitUntil("home state to reach .loading") { viewModel.state.isLoading }
        #expect(viewModel.state.isLoading)

        // A cancelled sleep returns immediately, so the same load still settles.
        load.cancel()
        await load.value

        guard case .loaded(let loaded) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(loaded.sections.map(\.title) == ["Continue Watching", "Trending Now"])
        #expect(repository.homeCallCount == 1)
        #expect(viewModel.sourceName == "Mock catalog")
    }

    @Test("a page whose rails are all empty becomes .empty")
    func emptyPage() async {
        let repository = MockCatalogRepository()
        repository.stubHome(Page(sections: [Section(title: "Continue Watching", items: [])]))
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.load()

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
    }

    @Test("a page with no sections at all is empty too")
    func sectionlessPage() async {
        let repository = MockCatalogRepository()
        repository.stubHome(Page(sections: []))
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.load()

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
    }

    @Test("a locked failure keeps the gate, an offline failure is a plain failure")
    func errorRouting() async {
        let lockedRepository = MockCatalogRepository()
        lockedRepository.failHome(.locked(reason: "Region blocked"))
        let lockedViewModel = HomeViewModel(repository: lockedRepository)
        await lockedViewModel.load()
        if case .locked(let error) = lockedViewModel.state {
            #expect(error == .locked(reason: "Region blocked"))
        } else {
            Issue.record("expected .locked, got \(lockedViewModel.state)")
        }

        let offlineRepository = MockCatalogRepository()
        offlineRepository.failHome(.offline)
        let offlineViewModel = HomeViewModel(repository: offlineRepository)
        await offlineViewModel.load()
        if case .failed(let error) = offlineViewModel.state {
            #expect(error == .offline)
        } else {
            Issue.record("expected .failed, got \(offlineViewModel.state)")
        }
    }

    @Test("loadIfNeeded fetches once across repeated appearances")
    func loadIfNeededFetchesOnce() async {
        let repository = MockCatalogRepository()
        repository.stubHome(page(["Trending Now"]))
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()
        #expect(repository.homeCallCount == 1)

        // A successful explicit load also marks the screen loaded, so the next
        // appearance still does not refetch.
        await viewModel.load()
        await viewModel.loadIfNeeded()
        #expect(repository.homeCallCount == 2)
    }

    @Test("a failure is not cached: loadIfNeeded retries and then settles")
    func retryAfterFailure() async {
        let repository = MockCatalogRepository()
        repository.failHome(.offline)
        let viewModel = HomeViewModel(repository: repository)

        await viewModel.loadIfNeeded()
        if case .failed(let error) = viewModel.state {
            #expect(error == .offline)
        } else {
            Issue.record("expected .failed, got \(viewModel.state)")
        }

        repository.stubHome(page(["Trending Now"]))
        await viewModel.loadIfNeeded()

        guard case .loaded(_) = viewModel.state else {
            Issue.record("expected .loaded after retry, got \(viewModel.state)")
            return
        }
        #expect(repository.homeCallCount == 2)
    }

    @Test("visibleSections removes hidden rails and keeps the rest in order")
    func visibleSections() async {
        let repository = MockCatalogRepository()
        repository.stubHome(page(["Continue Watching", "Trending Now", "New Releases"]))
        let viewModel = HomeViewModel(repository: repository)

        #expect(viewModel.visibleSections(hiding: []).isEmpty)

        await viewModel.load()

        #expect(
            viewModel.visibleSections(hiding: []).map(\.title)
                == ["Continue Watching", "Trending Now", "New Releases"]
        )
        #expect(
            viewModel.visibleSections(hiding: ["Trending Now"]).map(\.title)
                == ["Continue Watching", "New Releases"]
        )
        #expect(
            viewModel.visibleSections(hiding: ["Continue Watching", "New Releases"]).map(\.title)
                == ["Trending Now"]
        )
        #expect(
            viewModel.visibleSections(
                hiding: ["Continue Watching", "Trending Now", "New Releases"]
            ).isEmpty
        )
    }
}

// MARK: - Search

@Suite("SearchViewModel")
@MainActor
struct SearchViewModelTests {

    @Test("a blank query stays idle and never asks the repository")
    func blankQuery() async {
        let repository = MockCatalogRepository()
        let viewModel = SearchViewModel(repository: repository)

        viewModel.queryChanged("   \n ")
        if case .idle = viewModel.state {} else {
            Issue.record("expected .idle, got \(viewModel.state)")
        }
        #expect(viewModel.suggestions.isEmpty)
        #expect(repository.searchCallCount == 0)
        #expect(repository.suggestionsCallCount == 0)

        await viewModel.submit("\t")
        if case .idle = viewModel.state {} else {
            Issue.record("expected .idle after blank submit, got \(viewModel.state)")
        }
        #expect(repository.searchCallCount == 0)
        #expect(repository.suggestionsCallCount == 0)
    }

    @Test("submit trims the query and loads results plus suggestions")
    func submitLoadsResults() async {
        let repository = MockCatalogRepository()
        let dune = Subject(id: "1", title: "Dune")
        repository.stubSearch([dune])
        repository.stubSuggestions(["Dune Part Two", "Dune Messiah"])
        let viewModel = SearchViewModel(repository: repository)

        await viewModel.submit("  dune  ")

        guard case .loaded(let items) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(items == [dune])
        #expect(viewModel.suggestions == ["Dune Part Two", "Dune Messiah"])
        #expect(repository.searchQueries == ["dune"])
        #expect(repository.suggestionsQueries == ["dune"])
    }

    @Test("no matches is .empty, not a loaded empty list")
    func emptyResults() async {
        let repository = MockCatalogRepository()
        repository.stubSearch([])
        let viewModel = SearchViewModel(repository: repository)

        await viewModel.submit("zzzz")

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
    }

    @Test("a thrown search error becomes .failed, a locked one the gate")
    func searchErrors() async {
        let offlineRepository = MockCatalogRepository()
        offlineRepository.failSearch(.offline)
        let offlineViewModel = SearchViewModel(repository: offlineRepository)
        await offlineViewModel.submit("dune")
        if case .failed(let error) = offlineViewModel.state {
            #expect(error == .offline)
        } else {
            Issue.record("expected .failed, got \(offlineViewModel.state)")
        }

        let lockedRepository = MockCatalogRepository()
        lockedRepository.failSearch(.locked(reason: "Not in this region"))
        let lockedViewModel = SearchViewModel(repository: lockedRepository)
        await lockedViewModel.submit("dune")
        if case .locked(let error) = lockedViewModel.state {
            #expect(error == .locked(reason: "Not in this region"))
        } else {
            Issue.record("expected .locked, got \(lockedViewModel.state)")
        }
    }

    @Test("a failed suggestion lookup leaves the loaded results intact")
    func suggestionFailureIsSilent() async {
        let repository = MockCatalogRepository()
        let dune = Subject(id: "1", title: "Dune")
        repository.stubSearch([dune])
        repository.failSuggestions(.offline)
        let viewModel = SearchViewModel(repository: repository)

        await viewModel.submit("dune")

        guard case .loaded(let items) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(items == [dune])
        #expect(viewModel.suggestions.isEmpty)
    }

    @Test("clear resets the state and the suggestions")
    func clearResets() async {
        let repository = MockCatalogRepository()
        repository.stubSearch([Subject(id: "1", title: "Dune")])
        repository.stubSuggestions(["Dune Part Two"])
        let viewModel = SearchViewModel(repository: repository)

        await viewModel.submit("dune")
        viewModel.clear()

        if case .idle = viewModel.state {} else {
            Issue.record("expected .idle after clear, got \(viewModel.state)")
        }
        #expect(viewModel.suggestions.isEmpty)
    }

    @Test("queryChanged debounces: only the last keystroke reaches the repository")
    func debounceKeepsOnlyTheLastQuery() async {
        let repository = MockCatalogRepository()
        let second = Subject(id: "2", title: "Second")
        repository.stubSearch([second])
        let viewModel = SearchViewModel(repository: repository)

        viewModel.queryChanged("first")
        viewModel.queryChanged("second")

        // The window is ~280 ms; wait for the outcome, not for the clock.
        await waitUntil("the debounced query to reach the repository") {
            repository.searchCallCount == 1
        }
        await waitUntil("the search results to land") { viewModel.state.value == [second] }

        #expect(repository.searchQueries == ["second"])
        #expect(repository.searchCallCount == 1)

        // The superseded keystroke stays dead even after its window elapses.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(repository.searchCallCount == 1)
        #expect(repository.searchQueries == ["second"])
    }

    @Test("a slow in-flight search cannot win once a newer keystroke supersedes it")
    func supersededSlowSearchDoesNotWin() async {
        let repository = MockCatalogRepository()
        let slow = Subject(id: "slow", title: "Slow")
        let fast = Subject(id: "fast", title: "Fast")
        let viewModel = SearchViewModel(repository: repository)

        repository.stubSearch([slow])
        repository.setDelay(.seconds(30))
        viewModel.queryChanged("slow")
        await waitUntil("the slow query to reach the repository") {
            repository.searchCallCount == 1
        }

        // Replace the stalled answer and release the stall: the slow call was
        // already captured, so only the new keystroke can produce a result.
        repository.setDelay(.zero)
        repository.stubSearch([fast])
        viewModel.queryChanged("fast")
        await waitUntil("the superseding query to load") { viewModel.state.value == [fast] }

        guard case .loaded(let items) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(items == [fast])
        #expect(repository.searchQueries == ["slow", "fast"])
    }
}

// MARK: - Detail

@Suite("DetailViewModel")
@MainActor
struct DetailViewModelTests {

    private let series = Subject(id: "series", title: "Show", kind: "2", seasonCount: 2)
    private let movie = Subject(
        id: "movie", title: "Film", kind: "1", durationMinutes: 120
    )

    private func season(_ number: Int, episodes: Int) -> Season {
        Season(
            number: number,
            episodes: (1...episodes).map {
                Episode(subjectID: "series", season: number, number: $0, title: "S\(number)E\($0)")
            }
        )
    }

    @Test("a series loads its tree and defaults to the first season's first episode")
    func seriesDefaults() async {
        let repository = MockCatalogRepository()
        repository.stubDetail(series)
        repository.stubSeasons([season(1, episodes: 2), season(2, episodes: 1)])
        let viewModel = DetailViewModel(subject: series, repository: repository)

        await viewModel.load()

        guard case .loaded(let detail) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(detail.seasons.count == 2)
        #expect(viewModel.isSeries)
        #expect(viewModel.seasons.count == 2)
        #expect(viewModel.selectedSeason == 1)
        #expect(viewModel.selectedEpisode?.id == "series-s1e1")
        #expect(viewModel.episodes.map(\.number) == [1, 2])
        #expect(repository.detailCallCount == 1)
        #expect(repository.seasonsCallCount == 1)
        #expect(repository.seasonsQueries == ["series"])
    }

    @Test("the default season is the first in the tree, not always season 1")
    func defaultSeasonFollowsTree() async {
        let repository = MockCatalogRepository()
        repository.stubDetail(series)
        repository.stubSeasons([season(3, episodes: 1)])
        let viewModel = DetailViewModel(subject: series, repository: repository)

        await viewModel.load()

        #expect(viewModel.selectedSeason == 3)
        #expect(viewModel.selectedEpisode?.id == "series-s3e1")
    }

    @Test("selectSeason moves the episode to the new season's first")
    func selectSeasonMovesEpisode() async {
        let repository = MockCatalogRepository()
        repository.stubDetail(series)
        repository.stubSeasons([season(1, episodes: 2), season(2, episodes: 3)])
        let viewModel = DetailViewModel(subject: series, repository: repository)
        await viewModel.load()

        viewModel.selectSeason(2)
        #expect(viewModel.selectedSeason == 2)
        #expect(viewModel.selectedEpisode?.id == "series-s2e1")
        #expect(viewModel.episodes.map(\.number) == [1, 2, 3])

        // An explicit episode pick overrides the season default.
        let third = Episode(subjectID: "series", season: 2, number: 3)
        viewModel.selectEpisode(third)
        #expect(viewModel.selectedEpisode == third)

        // A season with no episodes clears the selection rather than keeping a
        // stale episode from the previous season.
        viewModel.selectSeason(9)
        #expect(viewModel.selectedSeason == 9)
        #expect(viewModel.selectedEpisode == nil)
        #expect(viewModel.episodes.isEmpty)
    }

    @Test("a movie never asks for a season tree")
    func movieSkipsSeasons() async {
        let repository = MockCatalogRepository()
        repository.stubDetail(movie)
        let viewModel = DetailViewModel(subject: movie, repository: repository)

        await viewModel.load()

        guard case .loaded(let detail) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(detail.seasons.isEmpty)
        #expect(viewModel.seasons.isEmpty)
        #expect(!viewModel.isSeries)
        #expect(viewModel.selectedEpisode == nil)
        #expect(viewModel.selectedSeason == 1)
        #expect(repository.seasonsCallCount == 0)
    }

    @Test("a thrown detail error lands in .failed")
    func detailError() async {
        let repository = MockCatalogRepository()
        repository.failDetail(.offline)
        let viewModel = DetailViewModel(subject: series, repository: repository)

        await viewModel.load()

        if case .failed(let error) = viewModel.state {
            #expect(error == .offline)
        } else {
            Issue.record("expected .failed, got \(viewModel.state)")
        }
        #expect(repository.seasonsCallCount == 0)
    }

    @Test("a failed season tree also fails the screen")
    func seasonTreeError() async {
        let repository = MockCatalogRepository()
        repository.stubDetail(series)
        repository.failSeasons(.upstream("no tree"))
        let viewModel = DetailViewModel(subject: series, repository: repository)

        await viewModel.load()

        if case .failed(let error) = viewModel.state {
            #expect(error == .upstream("no tree"))
        } else {
            Issue.record("expected .failed, got \(viewModel.state)")
        }
        #expect(repository.seasonsCallCount == 1)
    }

    @Test("a locked detail stays in the gate state")
    func lockedDetail() async {
        let repository = MockCatalogRepository()
        repository.failDetail(.locked(reason: "Device not allowed"))
        let viewModel = DetailViewModel(subject: series, repository: repository)

        await viewModel.load()

        if case .locked(let error) = viewModel.state {
            #expect(error == .locked(reason: "Device not allowed"))
        } else {
            Issue.record("expected .locked, got \(viewModel.state)")
        }
    }

    @Test("the first resource detector is the default language")
    func languageDefault() async {
        let detectors = [
            ResourceDetector(resourceId: "dub_en", name: "English"),
            ResourceDetector(resourceId: "sub_en", name: "English Sub"),
        ]
        let subject = Subject(
            id: "s", title: "Show", kind: "2", seasonCount: 1, resourceDetectors: detectors
        )
        let repository = MockCatalogRepository()
        repository.stubDetail(subject)
        repository.stubSeasons([Season(number: 1, episodes: [
            Episode(subjectID: "s", season: 1, number: 1),
        ])])
        let viewModel = DetailViewModel(subject: subject, repository: repository)

        #expect(viewModel.selectedLanguage == detectors[0])
        viewModel.selectLanguage(detectors[1])
        #expect(viewModel.selectedLanguage == detectors[1])
        viewModel.selectLanguage(nil)
        #expect(viewModel.selectedLanguage == nil)
    }
}

// MARK: - Watchlist and history screens

@Suite("WatchlistViewModel")
@MainActor
struct WatchlistViewModelTests {

    @Test("an empty store renders .empty")
    func emptyStore() async {
        let viewModel = WatchlistViewModel(library: InMemoryLibraryStore())

        await viewModel.load()

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
    }

    @Test("a populated store renders .loaded and remove mutates the store")
    func loadedAndRemove() async {
        let store = InMemoryLibraryStore()
        await store.toggleWatchlist(Subject(id: "1", title: "First"))
        try? await Task.sleep(for: .milliseconds(2))
        await store.toggleWatchlist(Subject(id: "2", title: "Second"))

        let viewModel = WatchlistViewModel(library: store)
        await viewModel.load()
        guard case .loaded(let entries) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(entries.map(\.subject.id) == ["2", "1"])

        await viewModel.remove(subjectID: "2")
        guard case .loaded(let remaining) = viewModel.state else {
            Issue.record("expected .loaded after remove, got \(viewModel.state)")
            return
        }
        #expect(remaining.map(\.subject.id) == ["1"])
        let stored = await store.watchlist()
        #expect(stored.map(\.subject.id) == ["1"])
    }

    @Test("removing the last entry collapses the state to .empty")
    func removeLastCollapsesToEmpty() async {
        let store = InMemoryLibraryStore()
        await store.toggleWatchlist(Subject(id: "1", title: "Only"))
        let viewModel = WatchlistViewModel(library: store)
        await viewModel.load()

        await viewModel.remove(subjectID: "1")

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
    }

    @Test("clear empties the store and the state")
    func clearEmpties() async {
        let store = InMemoryLibraryStore()
        await store.toggleWatchlist(Subject(id: "1", title: "First"))
        await store.toggleWatchlist(Subject(id: "2", title: "Second"))
        let viewModel = WatchlistViewModel(library: store)
        await viewModel.load()

        await viewModel.clear()

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
        let stored = await store.watchlist()
        #expect(stored.isEmpty)
    }
}

@Suite("HistoryViewModel")
@MainActor
struct HistoryViewModelTests {

    private func point(_ id: String, position: Double = 60) -> ResumePoint {
        ResumePoint(
            subjectID: id,
            title: id,
            positionSeconds: position,
            durationSeconds: 600
        )
    }

    @Test("an empty store renders .empty")
    func emptyStore() async {
        let viewModel = HistoryViewModel(library: InMemoryLibraryStore())

        await viewModel.load()

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
    }

    @Test("a populated store renders .loaded and remove mutates the store")
    func loadedAndRemove() async {
        let store = InMemoryLibraryStore()
        await store.record(point("a"))
        await store.record(point("b"))
        let viewModel = HistoryViewModel(library: store)

        await viewModel.load()
        guard case .loaded(let points) = viewModel.state else {
            Issue.record("expected .loaded, got \(viewModel.state)")
            return
        }
        #expect(Set(points.map(\.id)) == ["a", "b"])

        await viewModel.remove(id: "a")
        guard case .loaded(let remaining) = viewModel.state else {
            Issue.record("expected .loaded after remove, got \(viewModel.state)")
            return
        }
        #expect(remaining.map(\.id) == ["b"])
        let stored = await store.history()
        #expect(stored.map(\.id) == ["b"])
    }

    @Test("removing the last row collapses the state to .empty")
    func removeLastCollapsesToEmpty() async {
        let store = InMemoryLibraryStore()
        await store.record(point("a"))
        let viewModel = HistoryViewModel(library: store)
        await viewModel.load()

        await viewModel.remove(id: "a")

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
    }

    @Test("clear empties the store and the state")
    func clearEmpties() async {
        let store = InMemoryLibraryStore()
        await store.record(point("a"))
        await store.record(point("b"))
        let viewModel = HistoryViewModel(library: store)
        await viewModel.load()

        await viewModel.clear()

        if case .empty = viewModel.state {} else {
            Issue.record("expected .empty, got \(viewModel.state)")
        }
        let stored = await store.history()
        #expect(stored.isEmpty)
    }
}
