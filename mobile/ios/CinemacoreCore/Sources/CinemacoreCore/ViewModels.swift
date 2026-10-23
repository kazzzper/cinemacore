import Foundation
import Observation

/// Screen state holders.
///
/// These live in the Core package — not the app target — so their logic is
/// covered by `swift test` on Linux, where no simulator exists. They import
/// `Observation` but never SwiftUI, which keeps that boundary honest.

@MainActor
@Observable
public final class HomeViewModel {
    public private(set) var state: LoadState<Page> = .idle

    private let repository: any CatalogRepository
    private var loadedOnce = false

    public init(repository: any CatalogRepository) {
        self.repository = repository
    }

    public var sourceName: String { repository.sourceName }

    /// Loads on first appearance only, so tab switches do not refetch.
    public func loadIfNeeded() async {
        guard !loadedOnce else { return }
        await load()
    }

    public func load() async {
        guard !state.isLoading else { return }
        state = .loading
        do {
            let page = try await repository.home()
            loadedOnce = true
            state = page.isEmpty ? .empty : .loaded(page)
        } catch {
            state = error.requiresGate ? .locked(error) : .failed(error)
        }
    }

    /// Rails the user hid in Settings are filtered out before rendering.
    public func visibleSections(hiding hidden: Set<String>) -> [Section] {
        (state.value?.sections ?? []).filter { !hidden.contains($0.title) }
    }
}

@MainActor
@Observable
public final class SearchViewModel {
    public private(set) var state: LoadState<[Subject]> = .idle
    public private(set) var suggestions: [String] = []

    private let repository: any CatalogRepository
    private var pending: Task<Void, Never>?

    public init(repository: any CatalogRepository) {
        self.repository = repository
    }

    /// Debounced: a new keystroke cancels the in-flight request, so only the
    /// last one reaches the network.
    public func queryChanged(_ value: String) {
        pending?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .idle
            suggestions = []
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await self?.runSearch(trimmed)
        }
    }

    /// On submit the suggestion list stops mattering, so it is cleared.
    public func submit(_ value: String) async {
        pending?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestions = []
        guard !trimmed.isEmpty else {
            state = .idle
            return
        }
        await runSearch(trimmed)
    }

    public func clear() {
        pending?.cancel()
        state = .idle
        suggestions = []
    }

    private func runSearch(_ query: String) async {
        state = .loading
        do {
            let items = try await repository.search(query)
            guard !Task.isCancelled else { return }
            state = items.isEmpty ? .empty : .loaded(items)
            // Suggestions are a convenience; a failure must not surface as an
            // error because the results themselves are already on screen.
            suggestions = (try? await repository.suggestions(for: query)) ?? []
        } catch {
            guard !Task.isCancelled else { return }
            state = error.requiresGate ? .locked(error) : .failed(error)
        }
    }
}

@MainActor
@Observable
public final class DetailViewModel {
    public let subject: Subject
    public private(set) var state: LoadState<SubjectDetail> = .idle
    public private(set) var selectedSeason: Int = 1
    public private(set) var selectedEpisode: Episode?
    /// Provider dub/resource choices; the first is the default.
    public private(set) var languages: [ResourceDetector] = []
    public private(set) var selectedLanguage: ResourceDetector?

    private let repository: any CatalogRepository

    /// `season` preselects a season the caller already cares about — the row a
    /// viewer tapped in Downloads — so the page opens where they were rather
    /// than at season 1. It is honoured only when the title actually has it.
    public init(subject: Subject, repository: any CatalogRepository, season: Int? = nil) {
        self.subject = subject
        self.repository = repository
        self.selectedLanguage = subject.resourceDetectors.first
        if let season { self.selectedSeason = season }
    }

    public var seasons: [Season] { state.value?.seasons ?? [] }

    public var episodes: [Episode] {
        seasons.first { $0.number == selectedSeason }?.episodes ?? []
    }

    public var isSeries: Bool { subject.isSeries }

    public func load() async {
        guard !state.isLoading else { return }
        state = .loading
        do {
            // Sequential on purpose: the episode tree is only fetched when the
            // title is actually a series, which an `async let` would defeat by
            // starting the request eagerly. A direct `await` also keeps the
            // typed `CinemacoreError` intact, which `async let` widens to
            // `any Error`.
            let subject = try await repository.detail(id: subject.id)
            let tree = subject.isSeries ? try await repository.seasons(subjectID: subject.id) : []
            state = .loaded(SubjectDetail(subject: subject, seasons: tree))
            selectDefaultEpisode()
        } catch {
            state = error.requiresGate ? .locked(error) : .failed(error)
        }
    }

    public func selectSeason(_ number: Int) {
        selectedSeason = number
        // Keep the selection meaningful: pick the first episode of the new
        // season rather than leaving a stale episode from the old one.
        selectedEpisode = episodes.first
    }

    public func selectEpisode(_ episode: Episode) {
        selectedEpisode = episode
    }

    public func selectLanguage(_ language: ResourceDetector?) {
        selectedLanguage = language
    }

    private func selectDefaultEpisode() {
        guard isSeries else { return }
        // A requested season survives the load when the title has it; only a
        // season that does not exist falls back to the first.
        if !seasons.contains(where: { $0.number == selectedSeason }), let first = seasons.first {
            selectedSeason = first.number
        }
        if selectedEpisode == nil {
            selectedEpisode = episodes.first
        }
    }
}

@MainActor
@Observable
public final class WatchlistViewModel {
    public private(set) var state: LoadState<[WatchlistEntry]> = .idle
    private let library: any LibraryStoring

    public init(library: any LibraryStoring) {
        self.library = library
    }

    public func load() async {
        state = .loading
        let entries = await library.watchlist()
        state = entries.isEmpty ? .empty : .loaded(entries)
    }

    public func remove(subjectID: String) async {
        await library.removeFromWatchlist(subjectID: subjectID)
        await load()
    }

    public func clear() async {
        await library.clearWatchlist()
        await load()
    }
}

@MainActor
@Observable
public final class HistoryViewModel {
    public private(set) var state: LoadState<[ResumePoint]> = .idle
    private let library: any LibraryStoring

    public init(library: any LibraryStoring) {
        self.library = library
    }

    public func load() async {
        state = .loading
        let points = await library.history()
        state = points.isEmpty ? .empty : .loaded(points)
    }

    public func remove(id: String) async {
        await library.removeHistory(id: id)
        await load()
    }

    public func clear() async {
        await library.clearHistory()
        await load()
    }
}
