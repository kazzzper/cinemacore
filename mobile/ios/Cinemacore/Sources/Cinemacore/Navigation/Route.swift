import SwiftUI
import CinemacoreCore

/// What the user asked to play.
///
/// Carried as a value so the player is a pure function of its input rather than
/// reaching back into a shared view model.
struct PlaybackRequest: Hashable, Identifiable {
    let subject: Subject
    let season: Int?
    let episode: Episode?
    let resourceId: String?

    init(subject: Subject, season: Int? = nil, episode: Episode? = nil, resourceId: String? = nil) {
        self.subject = subject
        self.season = season
        self.episode = episode
        self.resourceId = resourceId
    }

    /// A movie is "season 0, episode 0" in the provider's vocabulary.
    var isMovie: Bool { episode == nil }

    var id: String {
        var value = subject.id
        if let season { value += "-s\(season)" }
        if let episode { value += "e\(episode.number)" }
        if let resourceId { value += "-r\(resourceId)" }
        return value
    }

    /// The identifier history is keyed by.
    ///
    /// Delegates to the store's own key builder so this spelling cannot drift
    /// away from ``ResumePoint/id`` and silently break resume.
    var historyID: String {
        ResumePoint.makeID(subjectID: subject.id, season: season, episode: episode?.number)
    }

    var title: String {
        guard let episode else { return subject.title }
        return "\(subject.title) · \(episode.displayTitle)"
    }
}

extension PlaybackRequest {
    /// Rebuilds the minimal request a stored row needs (history, downloads).
    ///
    /// The player re-resolves the full title from the provider, so only the
    /// identifying fields have to survive the round trip through the library.
    init(subjectID: String, title: String, poster: String?, season: Int?, episode: Int?) {
        let subject = Subject(
            id: subjectID,
            title: title,
            poster: poster,
            kind: episode == nil ? "movie" : "series"
        )
        let episodeValue = season.flatMap { season in
            episode.map { Episode(subjectID: subjectID, season: season, number: $0) }
        }
        self.init(subject: subject, season: season, episode: episodeValue)
    }
}

/// Every push destination in the app.
enum Route: Hashable {
    case detail(Subject)
    case player(PlaybackRequest)
    case history
    case manageCategories
    case docs
    case lab
}

/// Maps a ``Route`` to its screen.
///
/// One place, so a new destination cannot be reachable from one tab and missing
/// from another.
struct RouteDestination: View {
    let route: Route
    let app: AppModel

    var body: some View {
        switch route {
        case .detail(let subject):
            DetailScreen(subject: subject, app: app)
        case .player(let request):
            PlayerScreen(request: request, app: app)
        case .history:
            HistoryScreen(app: app)
        case .manageCategories:
            ManageCategoriesScreen(app: app)
        case .docs:
            DocsScreen()
        case .lab:
            LabScreen(app: app)
        }
    }
}

extension View {
    /// Installs the shared destination table on a navigation stack.
    func appRoutes(_ app: AppModel) -> some View {
        navigationDestination(for: Route.self) { route in
            RouteDestination(route: route, app: app)
        }
    }
}
