import Foundation

/// A `CatalogRepository` that talks to the MovieBox gateway directly, in native
/// Swift, with no gateway server involved.
///
/// A port of `core/provider/moviebox/moviebox.go`, which is the reference
/// implementation this must stay in step with. This is what lets the app run
/// standalone — the default source — with the HTTP gateway available only as a
/// deliberate override.
public struct MovieBoxCatalogRepository: CatalogRepository {
    private let session: MovieBoxSession

    public init(session: MovieBoxSession = MovieBoxSession()) {
        self.session = session
    }

    public var sourceName: String { "MovieBox" }
    public var isLive: Bool { true }

    public func home() async throws(CinemacoreError) -> Page {
        // home/v2/get-list answers 404 on every live host; the reference proxy
        // resolves it to tab-operating, so try the documented route first for a
        // cluster that serves it, then its resolution (Go Home()).
        if let page = try? await homeRails(
            path: "/home/v2/get-list",
            method: "POST",
            body: #"{"categoryId":1,"page":1,"pageSize":24}"#
        ), !page.isEmpty {
            return page
        }
        if let page = try? await homeRails(
            path: "/wefeed-mobile-bff/tab-operating?page=1&tabId=1&version=",
            method: "GET",
            body: nil
        ), !page.isEmpty {
            return page
        }
        // The single ranked feed is a last resort that keeps home answering.
        let daily: Envelope<ItemsPage> = try await envelope(
            "POST", "/wefeed-mobile-bff/subject-api/daily-movie-rec",
            body: #"{"page":1,"pageSize":20}"#
        )
        return Page(sections: [
            Section(title: "Top Picks", items: (daily.data?.items ?? []).map(\.subject))
        ])
    }

    public func search(_ query: String) async throws(CinemacoreError) -> [Subject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let body = #"{"keyword":"\#(escaped(trimmed))","q":"\#(escaped(trimmed))","type":0,"page":1,"pageSize":20}"#
        let page: Envelope<ItemsPage> = try await envelope(
            "POST", "/wefeed-mobile-bff/subject-api/search", body: body
        )
        return (page.data?.items ?? []).map(\.subject)
    }

    public func detail(id: String) async throws(CinemacoreError) -> Subject {
        let out: Envelope<WireSubject> = try await envelope(
            "GET", "/wefeed-mobile-bff/subject-api/get?subjectId=\(id)"
        )
        guard let subject = out.data else { throw .upstream("Unknown title.") }
        return subject.subject
    }

    public func seasons(subjectID: String) async throws(CinemacoreError) -> [Season] {
        let info: Envelope<SeasonInfo> = try await envelope(
            "GET", "/wefeed-mobile-bff/subject-api/season-info?subjectId=\(subjectID)"
        )
        // Rebuild rather than mutate: Season.episodes is immutable, and the
        // resource listing is the only endpoint carrying episode durations.
        let durations = (try? await episodeDurations(subjectID)) ?? [:]
        return (info.data?.seasons ?? []).compactMap { wire in
            guard let season = wire.season else { return nil }
            return Season(
                number: season.number,
                episodes: season.episodes.map { episode in
                    guard let seconds = durations[episodeKey(episode.season, episode.number)] else {
                        return episode
                    }
                    return Episode(
                        subjectID: episode.subjectID,
                        season: episode.season,
                        number: episode.number,
                        title: episode.title,
                        duration: episode.duration,
                        durationSeconds: seconds,
                        still: episode.still
                    )
                }
            )
        }
    }

    public func playInfo(
        subjectID: String,
        season: Int?,
        episode: Int?
    ) async throws(CinemacoreError) -> PlayInfo {
        var path = "/wefeed-mobile-bff/subject-api/play-info?subjectId=\(subjectID)"
        if let season, season > 0 { path += "&se=\(season)" }
        if let episode, episode > 0 { path += "&ep=\(episode)" }

        let info: Envelope<PlayInfoWire> = try await envelope("GET", path)
        if let primary = primaryStreams(from: info.data) {
            return await withCaptions(primary, subjectID: subjectID, season: season, episode: episode)
        }
        // Rung 3: the UGC download endpoints are the only recovery when
        // signCookie is empty (LocalMovieBoxServer.kt:835-940).
        if let ugc = try? await ugcBypass(subjectID: subjectID, season: season, episode: episode),
           !ugc.isEmpty {
            return await withCaptions(ugc, subjectID: subjectID, season: season, episode: episode)
        }
        // Rung 4: the resource listing as a second mirror source.
        if let resource = try? await resourceStream(subjectID: subjectID, season: season, episode: episode),
           !resource.isEmpty {
            return await withCaptions(resource, subjectID: subjectID, season: season, episode: episode)
        }
        // Never a decoy: an unplayable title fails honestly.
        throw CinemacoreError.upstream(
            (info.data?.streams.isEmpty ?? true)
                ? "No playback source for this title."
                : "This title is not playable in your region."
        )
    }

    /// Attaches the title's caption tracks to a resolved stream payload.
    ///
    /// The gateway publishes captions from a separate endpoint keyed on a
    /// resource id, so `/play-info` never carries them. Without this the
    /// player's subtitle sheet is permanently empty on the built-in source —
    /// the captions exist upstream and nothing ever asked for them.
    /// Best effort: a caption call that fails leaves the streams untouched.
    private func withCaptions(
        _ info: PlayInfo,
        subjectID: String,
        season: Int?,
        episode: Int?
    ) async -> PlayInfo {
        guard let tracks = try? await subtitleTracks(
            subjectID: subjectID,
            season: season,
            episode: episode
        ), !tracks.isEmpty
        else { return info }
        return PlayInfo(streams: info.streams, subtitles: tracks)
    }

    public func suggestions(for query: String) async throws(CinemacoreError) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let out: Envelope<Suggest> = try await envelope(
            "GET", "/wefeed-mobile-bff/subject-api/search-suggest?keyword=\(escaped(trimmed))"
        )
        return (out.data?.items ?? []).compactMap(\.word).filter { !$0.isEmpty }
    }

    // MARK: - Rungs 1-2: map play-info, never a decoy

    private func primaryStreams(from info: PlayInfoWire?) -> PlayInfo? {
        guard let info else { return nil }
        var renditions: [StreamRendition] = []
        var seen = Set<String>()
        var url: String?
        var cookie: String?

        for stream in info.streams {
            // An audio-only entry is not a playable source: handed to
            // `AVPlayer` it plays sound over a black surface, which the viewer
            // reads as a broken player. `format`/`codecName` are the only fields
            // that say so before the bytes are fetched.
            guard PlaybackSourcePolicy.isVideoStream(
                format: stream.format,
                codec: stream.codecName,
                url: stream.url
            ) else { continue }
            // Rung 1: the signed cookie carries the real CDN prefix and
            // outranks the advertised URL.
            let target = StreamRecovery.manifest(fromSignCookie: stream.signCookie ?? "")
                ?? (StreamRecovery.isUsable(stream.url ?? "") ? stream.url : nil)
            guard let target else { continue }
            if url == nil {
                url = target
                cookie = stream.signCookie
            }
            for rendition in StreamRecovery.renditions(
                url: target,
                resolutions: stream.resolutions ?? "",
                size: stream.size,
                cookie: stream.signCookie,
                codec: stream.codecName
            ) {
                let key = rendition.quality + "\u{0}" + rendition.url
                if seen.insert(key).inserted {
                    renditions.append(rendition)
                }
            }
        }
        guard let url else { return nil }
        if renditions.isEmpty {
            renditions = [StreamRendition(quality: "Auto", url: url, size: nil, cookie: cookie)]
        }
        return PlayInfo(
            streams: renditions.sorted {
                StreamRecovery.resolutionRank($0.quality) > StreamRecovery.resolutionRank($1.quality)
            },
            subtitles: []
        )
    }

    // MARK: - Rung 3: UGC bypass

    private func ugcBypass(subjectID: String, season: Int?, episode: Int?) async throws -> PlayInfo {
        let first: Envelope<UGCFirst> = try await envelope(
            "GET", "/wefeed-mobile-bff/ugc/video/first-by-subject?subjectId=\(subjectID)"
        )
        var resources: [UGCResource] = []
        if let collection = first.data?.belongToCollection?.collectionId, !collection.isEmpty {
            resources = try await ugcCollection(collectionID: collection, season: season, episode: episode)
        }
        // A single video under a collection subject is the show itself, i.e.
        // episode 1; for a later episode it is the same wrong-episode source
        // the collection matcher refuses, so it stays out of the way.
        if resources.isEmpty, (episode ?? 0) <= 1,
           let videoID = first.data?.ugcVideoId, !videoID.isEmpty {
            let download: Envelope<UGCDownload> = try await envelope(
                "GET", "/wefeed-mobile-bff/ugc/video/download?ugcVideoId=\(videoID)"
            )
            for item in download.data?.items ?? [] {
                resources.append(contentsOf: item.resources ?? [])
            }
        }
        return ugcPlayInfo(resources)
    }

    /// Matches the requested episode inside a UGC collection by its `S{se}EP{ep}`
    /// marker, falling back to the first item for episode 1 (Kotlin :864-890).
    private func ugcCollection(collectionID: String, season: Int?, episode: Int?) async throws -> [UGCResource] {
        let download: Envelope<UGCDownload> = try await envelope(
            "GET",
            "/wefeed-mobile-bff/ugc/collection/download-list?collectionId=\(collectionID)&page=1&perPage=50"
        )
        let items = download.data?.items ?? []
        let se = max(season ?? 1, 1)
        let ep = max(episode ?? 1, 1)
        var bare: [UGCResource]?
        for item in items {
            switch Self.ugcMarkerRank(
                epTitle: item.epTitle,
                title: item.title,
                season: se,
                episode: ep
            ) {
            case 2:
                return item.resources ?? []
            case 1:
                // Remembered, not returned: a later item may name the season
                // and episode exactly and outrank a bare episode marker.
                if bare == nil { bare = item.resources ?? [] }
            default:
                break
            }
        }
        if let bare { return bare }
        let marked = items.contains {
            Self.ugcHasEpisodeMarker(epTitle: $0.epTitle, title: $0.title)
        }
        if ep == 1, !marked, let first = items.first {
            return first.resources ?? []
        }
        return []
    }

    /// How strongly one collection item names the requested episode: `2` for a
    /// fully qualified `S{se}EP{ep}`, `1` for a bare `E{ep}`, `0` for neither.
    ///
    /// The rank lets an exact marker beat a bare one regardless of item order.
    /// `epTitle` is the dedicated marker field: when it names an episode, a
    /// contradictory title must not lend that item a different number.
    static func ugcMarkerRank(epTitle: String?, title: String?, season: Int, episode: Int) -> Int {
        let primary = (epTitle ?? "").uppercased()
        if hasEpisodeMarkerToken(primary) {
            return markerRank(in: primary, season: season, episode: episode)
        }
        let fallback = (title ?? "").uppercased()
        guard hasEpisodeMarkerToken(fallback) else { return 0 }
        return markerRank(in: fallback, season: season, episode: episode)
    }

    /// Whether any field carries an episode marker at all.
    ///
    /// Episode 1 may fall back to the first item, but only for a collection with
    /// no markers: a marked collection that does not name episode 1 is a
    /// mismatch, not an invitation to play the first episode.
    static func ugcHasEpisodeMarker(epTitle: String?, title: String?) -> Bool {
        hasEpisodeMarkerToken((epTitle ?? "").uppercased())
            || hasEpisodeMarkerToken((title ?? "").uppercased())
    }

    private static func markerRank(in hay: String, season: Int, episode: Int) -> Int {
        if containsNumberToken(hay, marker: "S\(season)EP\(episode)", digitBefore: false) {
            return 2
        }
        if containsNumberToken(hay, marker: "E\(episode)", digitBefore: true) {
            return 1
        }
        return 0
    }

    private static func hasEpisodeMarkerToken(_ hay: String) -> Bool {
        var index = hay.startIndex
        while index < hay.endIndex {
            if hay[index] == "E" {
                var next = hay.index(after: index)
                // `S1EP2` spells its marker with the E and P adjacent.
                if next < hay.endIndex, hay[next] == "P" {
                    next = hay.index(after: next)
                }
                if next < hay.endIndex, hay[next].isNumber { return true }
            }
            index = hay.index(after: index)
        }
        return false
    }

    /// `true` when `marker` is a complete token: a longer number after it names
    /// a different episode (`E1` inside `S1EP10`), and a preceding letter means
    /// it is part of a word. A digit may precede a bare `E` because `S1E2`
    /// spells the season directly before it.
    private static func containsNumberToken(_ hay: String, marker: String, digitBefore: Bool) -> Bool {
        var search = hay.startIndex
        while let range = hay.range(of: marker, range: search..<hay.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == hay.startIndex {
                beforeOK = true
            } else {
                let before = hay[hay.index(before: range.lowerBound)]
                beforeOK = digitBefore || (!before.isLetter && !before.isNumber)
            }
            let afterOK = range.upperBound == hay.endIndex
                || !hay[range.upperBound].isNumber
            if beforeOK, afterOK { return true }
            search = range.upperBound
        }
        return false
    }

    private func ugcPlayInfo(_ resources: [UGCResource]) -> PlayInfo {
        var renditions: [StreamRendition] = []
        var seen = Set<String>()
        for resource in resources where StreamRecovery.isUsable(resource.url ?? "")
            && PlaybackSourcePolicy.isVideoStream(format: nil, codec: nil, url: resource.url) {
            for label in StreamRecovery.splitList(resource.resolutions ?? "") {
                let key = label + "\u{0}" + (resource.url ?? "")
                if seen.insert(key).inserted {
                    renditions.append(
                        StreamRendition(
                            quality: label,
                            url: resource.url ?? "",
                            size: resource.size,
                            cookie: resource.signCookie,
                            codec: resource.codecName
                        )
                    )
                }
            }
        }
        return PlayInfo(
            streams: renditions.sorted {
                StreamRecovery.resolutionRank($0.quality) > StreamRecovery.resolutionRank($1.quality)
            },
            subtitles: []
        )
    }

    // MARK: - Rung 4: resource re-resolve

    private func resourceStream(subjectID: String, season: Int?, episode: Int?) async throws -> PlayInfo {
        let listing = try await resources(subjectID: subjectID, season: season, episode: episode)
        let items = Self.resourcesForEpisode(listing, season: season, episode: episode)
        var renditions: [StreamRendition] = []
        var seen = Set<String>()
        for item in items where StreamRecovery.isUsable(item.resourceLink ?? "")
            && PlaybackSourcePolicy.isVideoStream(format: nil, codec: nil, url: item.resourceLink) {
            let label = String(item.resolution)
            let key = label + "\u{0}" + (item.resourceLink ?? "")
            if seen.insert(key).inserted {
                renditions.append(
                    StreamRendition(
                        quality: label,
                        url: item.resourceLink ?? "",
                        size: item.size,
                        cookie: nil,
                        codec: item.codecName
                    )
                )
            }
        }
        return PlayInfo(
            streams: renditions.sorted {
                StreamRecovery.resolutionRank($0.quality) > StreamRecovery.resolutionRank($1.quality)
            },
            subtitles: []
        )
    }

    /// Narrows an unfiltered resource listing to the requested episode.
    ///
    /// The live cluster ignores `se`/`ep` on that endpoint, so without this every
    /// episode resolves to the listing's first item. A request that names no
    /// episode — a movie, or the season-duration scan — keeps the whole tree.
    static func resourcesForEpisode(
        _ items: [ResourceItem],
        season: Int?,
        episode: Int?
    ) -> [ResourceItem] {
        guard let episode, episode > 0 else { return items }
        let requestedSeason = (season ?? 0) > 0 ? season : nil
        return items.filter { item in
            guard item.ep == episode else { return false }
            guard let requestedSeason else { return true }
            return item.se == requestedSeason
        }
    }

    /// Pages the per-title resource listing. The listing is unfiltered by se/ep
    /// on the live cluster, so callers may pass nil for the whole tree.
    private func resources(subjectID: String, season: Int?, episode: Int?) async throws -> [ResourceItem] {
        var path = "/wefeed-mobile-bff/subject-api/resource?subjectId=\(subjectID)"
        if let season, season > 0 { path += "&se=\(season)" }
        if let episode, episode > 0 { path += "&ep=\(episode)" }
        var out: [ResourceItem] = []
        for page in 1...StreamRecovery.resourcePageLimit {
            let listing: Envelope<ResourcePage> = try await envelope(
                "GET", "\(path)&page=\(page)&perPage=50"
            )
            out.append(contentsOf: listing.data?.list ?? [])
            if listing.data?.pager?.hasMore != true { break }
        }
        return out
    }

    private func episodeDurations(_ subjectID: String) async throws -> [String: Int] {
        let items = try await resources(subjectID: subjectID, season: nil, episode: nil)
        var durations: [String: Int] = [:]
        for item in items where item.duration > 0 {
            let key = episodeKey(item.se, item.ep)
            if durations[key] == nil {
                durations[key] = item.duration
            }
        }
        return durations
    }

    private func episodeKey(_ season: Int, _ episode: Int) -> String {
        "\(season)-\(episode)"
    }

    // MARK: - Subtitles

    /// External caption tracks for one episode.
    ///
    /// Keyed by the title's first playable resourceId (Go Subtitles()). Every
    /// live title checked carries exactly one detector, so the first is the only
    /// one there is; a title with several uploads would need the playing one.
    ///
    /// `season` is sent as `se` alongside `episode`. The endpoint documents both
    /// and the client sent only the episode, which leaves a series ambiguous
    /// across seasons.
    public func subtitleTracks(
        subjectID: String,
        season: Int? = nil,
        episode: Int? = nil
    ) async throws(CinemacoreError) -> [SubtitleTrack] {
        let detail: Envelope<WireSubject> = try await envelope(
            "GET", "/wefeed-mobile-bff/subject-api/get?subjectId=\(subjectID)"
        )
        guard let rid = detail.data?.resourceDetectors?.first?.resourceId, !rid.isEmpty else {
            return []
        }
        var path = "/wefeed-mobile-bff/subject-api/get-ext-captions?subjectId=\(subjectID)&resourceId=\(rid)"
        if let season, season > 0 { path += "&se=\(season)" }
        if let episode, episode > 0 { path += "&episode=\(episode)" }
        let out: Envelope<Captions> = try await envelope("GET", path)
        return (out.data?.extCaptions ?? []).compactMap { caption in
            guard let url = caption.url, !url.isEmpty else { return nil }
            return SubtitleTrack(
                language: firstNonEmpty(caption.lanName, caption.lan),
                url: url,
                format: captionFormat(url),
                provider: .provider
            )
        }
    }

    // MARK: - Home rails

    private func homeRails(path: String, method: String, body: String?) async throws -> Page {
        let raw: Envelope<HomeRails> = try await envelope(method, path, body: body)
        var sections: [Section] = []
        for row in (raw.data?.items ?? []) + (raw.data?.list ?? []) {
            let items = row.allSubjects
            if !items.isEmpty {
                sections.append(Section(title: row.rowTitle.isEmpty ? "Section" : row.rowTitle, items: items))
            }
        }
        return Page(sections: sections)
    }

    // MARK: - Envelope handling

    /// One session call, as a result value rather than a throw.
    ///
    /// An async function that both declares a typed `throws(Error)` and contains
    /// a `do/catch` crashes the Swift 6.4.1 frontend during SIL lowering on
    /// Linux (reproduced minimally; see the progress notes). Returning a result
    /// keeps the typed surface at the protocol boundary without tripping the
    /// frontend, and the error mapping stays in one place.
    private enum RawResult {
        case data(Data)
        case failed(CinemacoreError)
    }

    private func raw(
        _ method: String,
        _ path: String,
        body: String?
    ) async -> RawResult {
        do {
            return .data(try await session.call(method, path, body: body))
        } catch {
            // `call` is typed-throws, so the binding is already a `SessionError`.
            return .failed(Self.map(error))
        }
    }

    private func envelope<T: Decodable>(
        _ method: String,
        _ path: String,
        body: String? = nil
    ) async throws(CinemacoreError) -> Envelope<T> {
        let payload = await raw(method, path, body: body)
        let data: Data
        switch payload {
        case .data(let value): data = value
        case .failed(let error): throw error
        }
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    static func map(_ error: MovieBoxSession.SessionError) -> CinemacoreError {
        switch error {
        case .noHosts:
            .offline
        case .transport(let code):
            .transport(code)
        case .http(let status, let body):
            .http(status: status, code: nil, message: body)
        case .badResponse:
            .upstream("The gateway returned an unreadable response.")
        }
    }

    // MARK: - Small helpers

    private func escaped(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The extension of the caption file, defaulting to SRT when the path has
    /// none. `AVPlayer` only renders WebVTT, and the converter also accepts an
    /// already-WebVTT body, so an extensionless caption can safely be converted
    /// instead of being fed to the VTT parser raw.
    private func captionFormat(_ rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return "srt" }
        let filename = url.path.split(separator: "/").last.map(String.init) ?? ""
        guard !filename.isEmpty,
              let dot = filename.lastIndex(of: "."),
              dot != filename.startIndex
        else { return "srt" }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        return ext.isEmpty || ext == "srt" ? "srt" : ext
    }
}
