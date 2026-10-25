import AVFoundation
import CinemacoreCore
import CoreMedia
import Foundation
import Observation
import UIKit

/// Audio codecs `AVPlayer` demonstrably does not decode on iOS.
///
/// A denylist rather than an allowlist: the platform gains decoders with OS
/// releases, and refusing an unfamiliar subtype would reject working audio.
private let undecodableAudioCodecs: Set<String> = [
    "dtsc", "dtsh", "dtsl", "dtse", "dtsx", "mlpa", "vorb", "wma1", "wma2",
    "spex", "ac-4", "mha1", "mhm1",
]

/// One audio track the container itself carries.
///
/// Deliberately not ``ResourceDetector``: that is the provider's dub list, which
/// costs a refetch, while this is a track switch inside the item already playing.
struct AudioTrack: Identifiable, Hashable {
    let option: AVMediaSelectionOption

    /// `AVMediaSelectionOption` is a class, and two options that read "English"
    /// are still different tracks, so identity is what the selection ring
    /// compares.
    var id: ObjectIdentifier { ObjectIdentifier(option) }

    /// Some containers expose an option with no display name, and a blank row in
    /// a picker is worse than the language tag.
    var label: String {
        option.displayName.isEmpty
            ? (option.locale?.identifier ?? "Audio track")
            : option.displayName
    }

    static func == (lhs: AudioTrack, rhs: AudioTrack) -> Bool { lhs.option === rhs.option }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(option)) }
}

/// The transient pill a ±10-second skip leaves on screen.
struct SkipIndicator: Identifiable, Equatable {
    let id = UUID()
    let seconds: Double

    var isForward: Bool { seconds > 0 }
    var text: String { "\(Int(abs(seconds).rounded())) seconds" }
}

/// Where the bytes for the current item come from.
private enum MediaSource {
    /// The CDN, addressed by a resolved rendition.
    case stream(StreamRendition, URL)
    /// A finished download: read from disk, with no HTTP request at all.
    case download(URL)
    /// A growing `.part` read through the in-process loopback server.
    case progressive(URL)

    var isLocal: Bool {
        if case .download = self { return true }
        return false
    }

    var isProgressive: Bool {
        if case .progressive = self { return true }
        return false
    }

    var url: URL? {
        switch self {
        case .stream(_, let url), .download(let url), .progressive(let url):
            url
        }
    }
}

/// The `AVPlayer` stack behind ``PlayerScreen``.
///
/// `@MainActor` because `AVPlayer` and `AVPlayerItem` are `NS_SWIFT_UI_ACTOR` in
/// the SDK: they serialise their change notifications on the main queue, so the
/// whole stack has to be touched there.
@MainActor
@Observable
final class PlayerModel {
    /// The player the video layer draws and the overlay drives.
    let player = AVPlayer()

    private(set) var state: LoadState<PlayInfo> = .idle
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isReloading = false
    private(set) var isFullscreen = false
    private(set) var controlsVisible = true
    private(set) var isScrubbing = false
    private(set) var isLocked = false
    private(set) var unlockHintVisible = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var activeCue: SubtitleCue?
    private(set) var skipIndicator: SkipIndicator?
    private(set) var volume: Double = 1
    private(set) var isMuted = false
    private(set) var isPiPActive = false
    private(set) var audioTracks: [AudioTrack] = []
    private(set) var selectedAudioTrack: AudioTrack?
    /// True while the bytes come from a finished download rather than the CDN.
    private(set) var isPlayingLocal = false
    /// True while the bytes come from a growing file through the loopback
    /// server. Distinct from ``isPlayingLocal`` because that read can fail
    /// before the item is complete, and the player then has a remote fallback.
    private(set) var isPlayingProgressive = false
    /// Set when the resolved playback is a `web`-kind rendition. The screen
    /// swaps the `AVPlayer` surface for a web view showing the embed page; the
    /// media state below (clock, duration, speed, captions) does not apply —
    /// the embed player owns all of that.
    ///
    /// Every path that builds an `AVPlayer` item must clear this. The screen's
    /// branch is `if let`, so a stale value from an earlier StreamHype playback
    /// keeps rendering the embed and hides the file the player is actually
    /// playing — a download that "won't play" is really playing invisibly
    /// behind a web view.
    private(set) var webStreamURL: URL?

    /// The episode (or movie) playing right now; an episode switch replaces it.
    private(set) var request: PlaybackRequest
    private(set) var seasons: [Season] = []
    private(set) var selectedSeason: Int
    private(set) var selectedLanguage: ResourceDetector?
    /// The provider subject for the chosen language version. A dub is a
    /// different subject upstream, not an audio track in the original file.
    private(set) var selectedDub: Dub?
    private(set) var selectedSubtitle: SubtitleTrack?
    private(set) var selectedRendition: StreamRendition?
    private(set) var speed = 1.0

    private let app: AppModel
    private let subtitleCache: SubtitleCache
    /// Keyless community captions, used only where the provider has none.
    private let freeSubtitles = FreeSubtitles()
    private let system = NowPlayingBridge()
    private let pictureInPicture = PictureInPicture()

    private var item: AVPlayerItem?
    private var urlAsset: AVURLAsset?
    private var audioGroup: AVMediaSelectionGroup?
    private var document: SubtitleDocument?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var endTask: Task<Void, Never>?
    private var pendingSeek: Double?
    private var controlsTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var skipTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var recordedAt: Date?
    private var stopped = false
    /// Set once the user picks a caption track, so late-arriving provider
    /// metadata cannot overwrite that choice.
    private var subtitleChosen = false
    /// A retry after a download that would not play goes back to the provider
    /// instead of reopening the same file.
    private var ignoresDownload = false
    /// Set for the rest of this playback once the loopback read has failed.
    /// The CDN remains usable, and reopening the same partial file would only
    /// fail again.
    private var ignoresProgressive = false
    /// Why the on-device copy was abandoned, when it was.
    ///
    /// Recovery leaves a rejected download and asks the provider instead. If
    /// that request is what fails, the screen must still name the file the
    /// viewer downloaded: reporting "offline" over a file sitting on disk sends
    /// them to check a network that had nothing to do with it.
    private var localRejection: String?
    private var isFallingBackFromProgressive = false
    private var lastAudibleVolume = 1.0
    /// Screen brightness this playback has taken over, 0…1.
    ///
    /// The picture is drawn by AVPlayer into a layer of the app's own view, so
    /// the only brightness that can be changed is the display's — which is what
    /// a left-edge swipe means in every video player.
    private(set) var brightness = Double(UIScreen.main.brightness)
    /// What the display was set to before this playback touched it, so leaving
    /// the player hands the device back the way it was found instead of
    /// leaving the phone dimmed after the film ends.
    private var brightnessBeforePlayback: Double?
    /// The source the current item was built from, kept so a quality pick can
    /// tell "same bytes, different hint" from "a different asset".
    private var currentSource: MediaSource?
    /// The provider rendition those bytes represent. For a local file this is
    /// the remote rendition it was downloaded from, not the file URL.
    private var currentRendition: StreamRendition?
    /// A remote URL that turned out to be audio-only or carry audio this device
    /// cannot decode. Session-scoped: re-resolving can hand back the same URL,
    /// and retrying it would reproduce the same black picture.
    private var unplayableSourceURLs: Set<String> = []
    /// Remote URLs already run through the `hev1` → `hvc1` repair, so a repaired
    /// source that still fails is not repaired again in a loop.
    private var repairedSourceURLs: Set<String> = []
    /// Language subjects recovery has already tried for this episode. Keyed per
    /// episode because the same dub is a different file from one episode to the
    /// next, so a rejection does not carry over.
    private var triedSourceIDs: Set<String> = []
    private var isInspectingSource = false
    /// The last measured verdict for the current item, kept so the picture
    /// watchdog can report the codec it saw rather than re-probing the asset.
    private var measuredInspection: SourceInspection?
    private var isRecoveringFromInvalidSource = false
    /// The layer on screen, and whether it has ever reported a frame.
    ///
    /// `isReadyForDisplay` is the only signal that reports what AVFoundation
    /// actually decoded rather than what the container claims, so it is the
    /// backstop for a track probe that could not decide — an audio-only asset
    /// whose probe threw, or a sample entry the device will not render.
    private weak var surface: AVPlayerLayer?
    private var surfaceObservation: NSKeyValueObservation?
    private var pictureConfirmed = false
    private var pictureTask: Task<Void, Never>?

    init(request: PlaybackRequest, app: AppModel) {
        self.request = request
        self.app = app
        selectedSeason = request.season ?? 1
        selectedLanguage = request.subject.resourceDetectors
            .first { $0.resourceId == request.resourceId }
            ?? request.subject.resourceDetectors.first
        // The original subject is the default language version. A stored
        // request does not carry a dub id, so this is the only safe default.
        selectedDub = request.subject.dubOptions.first { $0.isOriginal }

        subtitleCache = SubtitleCache(
            directory: URL.cachesDirectory.appendingPathComponent("Subtitles", isDirectory: true)
        )
        // The stored rate is a preference, not a contract: a document written by
        // another build could hold a speed this sheet cannot represent.
        let saved = app.settings.playbackSpeed
        speed = PlayInfo.speedOptions.contains(saved) ? saved : 1

        pictureInPicture.onChange = { [weak self] active in self?.isPiPActive = active }
    }

    // MARK: - Derived state

    var renditions: [StreamRendition] {
        PlaybackSourcePolicy.videoOptions(state.value?.streams ?? [])
    }
    var subtitleTracks: [SubtitleTrack] { state.value?.subtitles ?? [] }

    /// The sources this episode actually has tracks from, in picker order.
    ///
    /// A source section is only offered when it has something in it: an empty
    /// "Community" row would claim tracks exist when the lookup found none.
    var subtitleSources: [SubtitleSource] {
        SubtitleSource.allCases.filter { source in
            subtitleTracks.contains { $0.provider == source }
        }
    }

    /// The tracks belonging to one source, in the order the source listed them.
    func subtitleTracks(from source: SubtitleSource) -> [SubtitleTrack] {
        subtitleTracks.filter { $0.provider == source }
    }

    /// The source of the track on screen, or `nil` when captions are off.
    var selectedSubtitleSource: SubtitleSource? { selectedSubtitle?.provider }
    var languages: [ResourceDetector] { request.subject.resourceDetectors }
    /// Language versions the provider advertises for this title.
    var dubOptions: [Dub] { request.subject.dubOptions }
    var isSeries: Bool { request.subject.isSeries }
    var playingEpisode: Episode? { request.episode }
    var seasonNumbers: [Int] { seasons.map(\.number) }

    var episodes: [Episode] {
        seasons.first { $0.number == selectedSeason }?.episodes ?? []
    }

    /// Every episode in transmission order, which is the order next and previous
    /// walk — including across a season boundary.
    private var orderedEpisodes: [Episode] { seasons.flatMap(\.episodes) }

    private var currentEpisodeIndex: Int? {
        guard isSeries, let current = request.episode else { return nil }
        return orderedEpisodes.firstIndex { $0.id == current.id }
    }

    var nextEpisode: Episode? {
        guard let index = currentEpisodeIndex,
              orderedEpisodes.indices.contains(index + 1) else { return nil }
        return orderedEpisodes[index + 1]
    }

    var previousEpisode: Episode? {
        guard let index = currentEpisodeIndex, index > 0 else { return nil }
        return orderedEpisodes[index - 1]
    }

    var hasNextEpisode: Bool { nextEpisode != nil }
    var hasPreviousEpisode: Bool { previousEpisode != nil }
    var languageLabel: String { selectedLanguage?.name ?? "Default" }
    var dubLabel: String { selectedDub?.displayName ?? "Original Audio" }
    /// The subject whose streams/subtitles are resolved. History and downloads
    /// stay keyed to the original title, so a dub switch cannot split progress.
    private var playbackSubjectID: String {
        selectedDub?.subjectId ?? request.subject.id
    }
    var subtitleLabel: String { selectedSubtitle?.language ?? "Off" }
    /// The source line under the language, so the controls say *which* English
    /// track is on rather than only that English is.
    var subtitleSourceLabel: String? { selectedSubtitle?.detail }
    var qualityLabel: String { selectedRendition?.quality ?? "Auto" }
    var speedLabel: String { Self.speedText(speed) }
    var canStartPictureInPicture: Bool { PictureInPicture.isSupported && item != nil }
    var volumeSymbol: String { isMuted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill" }

    /// The line under the title on the lock screen.
    var nowPlayingSubtitle: String? {
        guard let episode = request.episode else { return nil }
        return "\(request.subject.title) · S\(episode.season) E\(episode.number)"
    }

    /// `1.0` reads as "Normal" rather than "1.0x", matching the Android sheet.
    static func speedText(_ value: Double) -> String {
        guard value != 1 else { return "Normal" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2))))x"
    }

    /// `mm:ss` under the hour and `h:mm:ss` past it, so a 65-minute film reads
    /// `1:05:30` rather than `65:30`.
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        guard hours > 0 else {
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
    }

    /// `-12:30`: what is left, which is the label a player owes the viewer more
    /// than the duration they can already see on the scrubber.
    static func remainingText(position: Double, duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "-00:00" }
        return "-" + timeText(max(duration - position, 0))
    }

    // MARK: - Lifecycle

    /// First appearance: claim the audio session, then resolve and play.
    func start() async {
        activateAudioSession()
        installTimeObserver()
        observePlaybackStatus()
        system.attach(to: self)
        await load()
    }

    /// Last appearance: persist the position, release the player, and hand the
    /// audio session and the idle timer back to the system.
    func stop() {
        guard !stopped else { return }
        stopped = true
        // Only when this playback changed it: a viewer who dimmed the phone
        // before pressing play keeps their own setting.
        if let original = brightnessBeforePlayback {
            UIScreen.main.brightness = CGFloat(original)
            brightnessBeforePlayback = nil
        }
        controlsTask?.cancel()
        subtitleTask?.cancel()
        audioTask?.cancel()
        skipTask?.cancel()
        unlockTask?.cancel()
        stopPictureWatch()

        let clock = player.currentTime().seconds
        if clock.isFinite, clock > 0 { position = clock }
        record()

        player.pause()
        pictureInPicture.detach()
        system.stop()
        // A web playback disappears with the screen, so the web view is torn
        // down here rather than continuing to load behind the library.
        webStreamURL = nil
        // Leaving fullscreen by leaving the screen still has to give the device
        // its orientation back.
        if isFullscreen {
            isFullscreen = false
            PlayerOrientation.setFullscreen(false)
        }

        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        playbackObservation?.invalidate()
        playbackObservation = nil
        endTask?.cancel()
        endTask = nil
        player.replaceCurrentItem(with: nil)
        item = nil
        urlAsset = nil
        audioGroup = nil
        currentSource = nil
        currentRendition = nil
        UIApplication.shared.isIdleTimerDisabled = false
        deactivateAudioSession()
    }

    // MARK: - Loading

    /// Resolves the source and rebuilds the item.
    ///
    /// `restartAt` overrides where playback resumes; `nil` means "the position
    /// the library saved for this episode".
    func load(restartAt: Double? = nil) async {
        if state.value == nil { state = .loading } else { isReloading = true }
        // A fresh source resets the captions, so a choice made for the previous
        // episode cannot block the new one's default track.
        subtitleChosen = false
        defer { isReloading = false }

        // A finished download outranks the network: it is the one source that
        // works with no connection at all, and it starts without a round trip.
        if !ignoresDownload, let download = downloadedItem() {
            await playDownload(download, restartAt: restartAt)
            return
        }
        // An in-progress direct file is next: its committed prefix is already
        // local, and the loopback server can start before the queue finishes.
        if !ignoresProgressive, let partial = await progressiveItem() {
            await playProgressive(partial, restartAt: restartAt)
            return
        }
        await playStream(restartAt: restartAt)
    }

    /// The finished download for exactly this episode, if the user has one.
    ///
    /// The queue holds at most one entry per episode and quality, so the first
    /// completed match is the only sensible pick; every candidate plays the same
    /// file from disk either way.
    private func downloadedItem() -> DownloadItem? {
        app.downloads.first {
            $0.status == .completed
                && isForThisEpisode($0)
                // A file already proved to have no video is not a source; the
                // provider copy (or another rendition) is the way forward.
                && !unplayableSourceURLs.contains(
                    PlaybackSourcePolicy.sourceKey(app.localFileURL(for: $0))
                )
                // A queue written before downloads filtered audio-only rungs can
                // hold a soundtrack. It completed and it is playable — as sound
                // over a black surface — so it is not the copy worth opening.
                && PlaybackSourcePolicy.isVideoCapable(
                    StreamRendition(
                        quality: $0.quality,
                        url: $0.remoteURL.absoluteString
                    )
                )
        }
    }

    /// A finished copy of exactly this episode, whether or not it can play.
    ///
    /// ``downloadedItem()`` answers "what may I open"; this answers "did the
    /// viewer already download this". The difference matters only once every
    /// source has failed, because a file on disk changes what that failure
    /// means — and only this one can be fixed from the Downloads screen.
    private func completedCopy() -> DownloadItem? {
        app.downloads.first { $0.status == .completed && isForThisEpisode($0) }
    }

    private func isForThisEpisode(_ item: DownloadItem) -> Bool {
        item.subjectID == request.subject.id
            && item.season == request.season
            && item.episode == request.episode?.number
    }

    /// A still-growing file the loopback server can already serve.
    ///
    /// Readiness is re-checked here rather than taken from the Downloads row:
    /// bytes may have arrived since that list was built.
    private func progressiveItem() async -> DownloadItem? {
        for item in app.downloads {
            guard item.status != .completed,
                  item.container.isDirectDownload,
                  item.subjectID == request.subject.id,
                  item.season == request.season,
                  item.episode == request.episode?.number
            else { continue }
            guard await app.isProgressiveReady(item),
                  let url = await app.progressiveURL(for: item),
                  !unplayableSourceURLs.contains(PlaybackSourcePolicy.sourceKey(url))
            else { continue }
            return item
        }
        return nil
    }

    private func playStream(restartAt: Double?) async {
        // The bytes are the provider's again. Leaving the local flags set would
        // keep the "Downloaded" badge on a streamed title, blame the download in
        // an error message, and make `retry()` skip the download for good.
        isPlayingLocal = false
        isPlayingProgressive = false
        do {
            let info = try await app.repository.playInfo(
                subjectID: playbackSubjectID,
                season: request.season,
                episode: request.episode?.number
            )
            await loadSeasons()
            // A resolve that lands after the screen is gone must not build an
            // item nobody can stop: `stop()` has already released the player.
            guard !stopped, !Task.isCancelled else { return }
            guard !info.isEmpty else {
                haltTerminalPlayback()
                enterTerminalState(.empty)
                return
            }
            state = .loaded(info)
            resetSelections(for: info)

            // A web embed never reaches `AVPlayer`: the URL is a player page,
            // and handing it to the media stack would produce a black surface
            // and a dead scrubber. The screen renders the embed instead, and
            // the embed player owns the clock — the media state machine stays
            // untouched for this playback.
            if let stream = selectedRendition, stream.isWebEmbed {
                guard let url = stream.urlValue else {
                    haltTerminalPlayback()
                    enterTerminalState(.failed(.upstream("The embed URL is not usable.")))
                    return
                }
                webStreamURL = url
                return
            }

            guard let stream = selectedRendition, let url = stream.urlValue else {
                haltTerminalPlayback()
                // Streams existed but every one was audio-only or unusable;
                // `.empty` would claim the provider sent nothing.
                enterTerminalState(
                    info.streams.isEmpty
                        ? .empty
                        : .failed(.upstream("This title has no playable video source."))
                )
                return
            }
            rebuild(.stream(stream, url), startingAt: await resume(restartAt))
            // After `rebuild`, so the picture never waits on a caption search.
            await hydrateFreeSubtitles()
        } catch {
            guard !stopped, !Task.isCancelled else { return }
            // Last look at the queue before blaming the network: a download that
            // landed after `load()` checked the queue is still the copy that
            // works with no connection, and reporting the provider as
            // unreachable while it sits on disk is the wrong answer.
            // A gate error is a decision about this session, not a source failure:
            // the unlock screen has to be shown even when a local copy exists.
            if !ignoresDownload, !error.requiresGate, let download = downloadedItem() {
                await playDownload(download, restartAt: restartAt)
                return
            }
            // A rejected copy is the reason playback stopped; the provider call
            // was only the second failure. Naming the network here would hide
            // the file the viewer can act on.
            if let localRejection, Self.isTransportFailure(error) {
                haltTerminalPlayback()
                enterTerminalState(.failed(.upstream(localRejection)))
                return
            }
            // A copy is on disk but the queue row itself said it cannot be
            // video — a soundtrack queued by an older build — so it was never
            // opened. Blaming the network would send the viewer to fix the
            // wrong thing.
            if Self.isTransportFailure(error), completedCopy() != nil {
                haltTerminalPlayback()
                enterTerminalState(.failed(.upstream(
                    "The downloaded copy of this episode cannot be played. Delete it in Downloads and download it again."
                )))
                return
            }
            haltTerminalPlayback()
            enterTerminalState(error.requiresGate ? .locked(error) : .failed(error))
        }
    }

    /// A screen with no picture has no subject to fill, so it must give the
    /// system bars and the failure card their normal portrait frame back.
    private func enterTerminalState(_ newState: LoadState<PlayInfo>) {
        state = newState
        guard isFullscreen else { return }
        setFullscreen(false)
    }

    /// A second caption source, so a title the provider publishes none for — or
    /// publishes only one track for — still offers a choice.
    ///
    /// Runs whenever no community track is already listed, whatever the
    /// provider returned: the two sources are different subtitles, and the
    /// viewer is the one who can tell which matches their file. It never blocks
    /// playback: the item is already being built when this is awaited.
    private func hydrateFreeSubtitles() async {
        guard !stopped, !Task.isCancelled, !subtitleChosen,
              case .loaded(let current) = state,
              !current.subtitles.contains(where: { $0.provider == .community })
        else { return }

        let request = FreeSubtitleRequest(
            title: request.subject.title,
            year: request.subject.year,
            isSeries: isSeries,
            season: request.season,
            episode: request.episode?.number,
            language: app.settings.preferredLanguage
        )
        let tracks = await freeSubtitles.tracks(for: request)
        // The item, the episode and the viewer's own choice can all have moved
        // on while the search was in flight.
        guard !stopped, !Task.isCancelled, !tracks.isEmpty, !subtitleChosen,
              case .loaded(let latest) = state,
              !latest.subtitles.contains(where: { $0.provider == .community })
        else { return }

        let merged = SubtitleTracks.merging(latest.subtitles, with: tracks)
        state = .loaded(PlayInfo(streams: latest.streams, subtitles: merged))
        // Only a viewer who has not chosen gets a default; the pick they made
        // while this was in flight stands.
        guard selectedSubtitle == nil else { return }
        selectedSubtitle = SubtitleTracks.defaultTrack(
            in: merged,
            isOriginalAudio: selectedDub?.isOriginal != false,
            chosen: nil
        )
        loadSubtitles()
    }

    /// Plays a finished download, then asks the provider only for what a file
    /// cannot carry: the caption tracks and the episode tree.
    private func playDownload(_ download: DownloadItem, restartAt: Double?) async {
        let url = app.localFileURL(for: download)
        let rendition = rendition(for: download)
        // Captions were saved with the episode, so a playback with no connection
        // still offers them. A title that has none seeds the same empty list a
        // captionless stream would.
        let saved = app.subtitleTracks(for: download)
        state = .loaded(PlayInfo(streams: [rendition], subtitles: saved))
        selectedRendition = rendition
        currentRendition = rendition
        selectedSubtitle = SubtitleTracks.defaultTrack(
            in: saved,
            isOriginalAudio: selectedDub?.isOriginal != false,
            chosen: nil
        )

        // Started before the metadata round trip, so a downloaded episode begins
        // instantly and plays with no connection whatsoever.
        rebuild(.download(url), startingAt: await resume(restartAt))
        await hydrateProviderMetadata()
    }

    /// Plays the committed prefix of an in-progress download through the
    /// loopback server. The provider is still asked for captions and the
    /// episode tree; the file itself never leaves the device.
    private func playProgressive(_ download: DownloadItem, restartAt: Double?) async {
        guard let url = await app.progressiveURL(for: download) else {
            // The server stopped, or the item completed between the readiness
            // check and this call: the provider is still a valid source.
            await playStream(restartAt: restartAt)
            return
        }
        let rendition = rendition(for: download)
        state = .loaded(PlayInfo(streams: [rendition], subtitles: []))
        selectedRendition = rendition
        currentRendition = rendition
        selectedSubtitle = nil

        rebuild(.progressive(url), startingAt: await resume(restartAt))
        await hydrateProviderMetadata()
    }

    /// The provider rendition a local item stands for: what the quality sheet
    /// names and what Download re-queues. The file travels in the source, so
    /// this value is never handed to the player.
    private func rendition(for download: DownloadItem) -> StreamRendition {
        StreamRendition(
            quality: download.quality,
            url: download.remoteURL.absoluteString,
            size: download.sizeText,
            cookie: download.cookie
        )
    }

    /// The provider still owns the episode tree and the caption tracks, neither
    /// of which a downloaded file carries. Best effort by design: with no
    /// connection this returns having changed nothing, and playback continues.
    private func hydrateProviderMetadata() async {
        await loadSeasons()
        guard !stopped, !Task.isCancelled else { return }
        guard let info = try? await app.repository.playInfo(
            subjectID: playbackSubjectID,
            season: request.season,
            episode: request.episode?.number
        ), !info.isEmpty else { return }
        guard !stopped, !Task.isCancelled, case .loaded(let current) = state else { return }

        // Merged, not replaced: the viewer may already be watching a community
        // track this payload does not carry, and dropping it would leave the
        // picker with no selected row while that track still plays.
        state = .loaded(PlayInfo(
            streams: current.streams,
            subtitles: SubtitleTracks.merging(current.subtitles, with: info.subtitles)
        ))
        guard !subtitleChosen, selectedSubtitle == nil, selectedDub?.isOriginal != false,
              let first = info.subtitles.first else {
            // A download with no provider captions is the same captionless case
            // a stream can be, so it gets the same second chance.
            await hydrateFreeSubtitles()
            return
        }
        selectedSubtitle = first
        loadSubtitles()
    }


    /// Stops the current item when the screen falls back to an error or empty
    /// state, so audio never plays behind a UI that no longer shows it.
    private func haltTerminalPlayback() {
        guard item != nil else { return }
        player.pause()
    }

    /// Re-resolves the source after a failure.
    ///
    /// A failure mid-playback keeps the clock so the user does not lose their
    /// place; an initial failure falls back to the saved position.
    func retry() async {
        // A file that will not decode is not fixed by opening it again, so a
        // retry of a broken download goes back to the provider.
        ignoresDownload = isPlayingLocal
        await load(restartAt: position > 0 ? position : nil)
        ignoresDownload = false
    }

    /// Moves a failed loopback read onto the provider at the same clock.
    ///
    /// No attempt counter is spent here: the item itself did not fail, its
    /// local source did, and the remote stream is the same title.
    private func fallbackFromProgressive() async {
        guard !stopped else {
            isFallingBackFromProgressive = false
            return
        }
        let restart = position > 0 ? position : pendingSeek
        ignoresProgressive = true
        await load(restartAt: restart)
        ignoresProgressive = false
        isFallingBackFromProgressive = false
    }

    /// The episode tree only drives the season/episode sheets and auto-advance.
    ///
    /// A failure here is deliberately non-fatal: playback does not depend on it,
    /// so those panels simply have nothing to offer.
    private func loadSeasons() async {
        guard isSeries, seasons.isEmpty else { return }
        let loaded = (try? await app.repository.seasons(subjectID: playbackSubjectID)) ?? []
        guard !stopped, !Task.isCancelled else { return }
        seasons = loaded
        if let season = request.season, seasons.contains(where: { $0.number == season }) {
            selectedSeason = season
        } else if let first = seasons.first {
            selectedSeason = first.number
        }
    }

    /// The key the library store writes, taken from the store's own builder so
    /// a second spelling cannot silently miss.
    private var historyKey: String {
        ResumePoint.makeID(
            subjectID: request.subject.id,
            season: request.season,
            episode: request.episode?.number
        )
    }

    /// The caller's override when it has one, otherwise the library's position.
    private func resume(_ restartAt: Double?) async -> Double? {
        if let restartAt { return restartAt }
        return await savedPosition()
    }

    /// Resumes silently — the Android build offered no "start over" prompt, and
    /// matching it is deliberate.
    private func savedPosition() async -> Double? {
        guard let point = await app.resumePoint(for: historyKey), point.isResumable else { return nil }
        return point.positionSeconds
    }

    /// Mirrors the Android `selectEpisode`/`selectLanguageResource` resets: a
    /// fresh payload starts on the preferred rendition and the first caption
    /// track — off entirely for a dub, whose own audio is that language.
    private func resetSelections(for info: PlayInfo) {
        let candidates = PlaybackSourcePolicy.videoCandidates(info.streams)
        // A URL already proved unplayable is only revisited when it is the sole
        // option; otherwise the default would walk straight back into it.
        selectedRendition = candidates.first { !unplayableSourceURLs.contains(PlaybackSourcePolicy.sourceKey($0)) }
            ?? candidates.first
        // A dub already speaks the requested language, so an original-language
        // caption track is not the default there. The picker still offers any
        // captions the dub's own payload carries.
        selectedSubtitle = SubtitleTracks.defaultTrack(
            in: info.subtitles,
            isOriginalAudio: selectedDub?.isOriginal != false,
            chosen: nil
        )
    }

    private func rebuild(_ source: MediaSource, startingAt seconds: Double?) {
        // Every path that hands `AVPlayer` an item starts here, so this is where
        // a previous playback's embed page is retired. The screen's `if let`
        // would otherwise keep the web view up and the new item invisible.
        webStreamURL = nil
        // A new source supersedes the old verdict: whatever failed before is not
        // what is playing now, so it cannot explain a future network failure.
        localRejection = nil
        let asset: AVURLAsset
        switch source {
        case .stream(let rendition, let url):
            asset = AVURLAsset(url: url, options: [
                Self.headerFieldsKey: MediaRequest.headers(cookie: rendition.cookie),
            ])
        case .download(let fileURL):
            // A file has no request to sign or shape; attaching the CDN's cookie
            // to a local read would be meaningless at best.
            asset = AVURLAsset(url: fileURL)
        case .progressive(let loopbackURL):
            // The loopback server reads this app's own `.part`; the CDN cookie
            // authenticates the origin, not this local hop.
            asset = AVURLAsset(url: loopbackURL)
        }
        isPlayingLocal = source.isLocal
        isPlayingProgressive = source.isProgressive
        currentSource = source
        if case .stream(let rendition, _) = source {
            currentRendition = rendition
        }
        isInspectingSource = false
        measuredInspection = nil

        let item = AVPlayerItem(asset: asset)
        // `.timeDomain` is the cheap resampler: at pitch-preserved speeds it
        // smears transients and makes music sound reverberant. `.spectral` is
        // the algorithm AVPlayer uses for movies and the one that keeps
        // dialogue intelligible at 1.25x and 0.5x.
        item.audioTimePitchAlgorithm = .spectral
        if case .stream(let rendition, _) = source {
            item.preferredPeakBitRate = Self.bitrateHint(for: rendition)
        }
        urlAsset = asset
        self.item = item
        pendingSeek = seconds
        observe(item)
        player.replaceCurrentItem(with: item)
        playbackStateChanged()
        loadSubtitles()
        loadAudioTracks()
        play()
    }

    /// The option key that puts `User-Agent` and `Cookie` on every request the
    /// asset makes.
    ///
    /// Undocumented — absent from the public AVFoundation headers, unlike
    /// `AVURLAssetHTTPCookiesKey` — but `AVURLAsset` honours it, and it is the
    /// only way to send both headers at once. Media and subtitle requests carry
    /// those two headers and nothing else: no signature headers, by contract.
    private static let headerFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    /// A quality pick is a hint, never a different URL: the gateway repeats one
    /// URL under every label, so the choice becomes a peak-bit-rate ceiling for
    /// the adaptive ladder. `Auto` — and anything that is not an HLS ladder —
    /// leaves it unlimited: capping a progressive file whose own bitrate sits
    /// above the ceiling is how a pick ends up stalling on a black frame.
    private static func bitrateHint(for stream: StreamRendition) -> Double {
        guard stream.urlValue?.pathExtension.lowercased() == "m3u8" else { return 0 }
        return switch stream.resolutionRank {
        case 2160...: 16_000_000
        case 1440...: 10_000_000
        case 1080...: 6_000_000
        case 720...: 3_000_000
        case 480...: 1_500_000
        case 360...: 800_000
        default: 0
        }
    }

    // MARK: - Observation

    private func observe(_ item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            // KVO is not actor-annotated, so hop instead of assuming: a wrong
            // `assumeIsolated` would trap where a late update merely lags.
            Task { @MainActor in self?.itemStatusChanged() }
        }

        endTask?.cancel()
        // The notification sequence is the structured-concurrency replacement
        // for a completion-handler observer: cancelling the task unsubscribes.
        endTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification,
                object: item
            ) {
                guard let self else { return }
                await self.itemDidPlayToEnd()
            }
        }
    }

    private func observePlaybackStatus() {
        guard playbackObservation == nil else { return }
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.playbackStateChanged() }
        }
    }

    /// A quarter second is the caption overlay's resolution; polling with a
    /// `Timer` would drift against the playhead and cost more.
    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // `queue: .main` is a promise, so isolation can be assumed here
            // rather than hopping four times a second.
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        position = seconds
        refreshCue()
        recordIfDue()
    }

    private func itemStatusChanged() {
        guard let item else { return }
        switch item.status {
        case .readyToPlay:
            isBuffering = false
            let loaded = item.duration.seconds
            if loaded.isFinite, loaded > 0 { duration = loaded }
            applyPendingSeek()
            publishNowPlaying()
            inspectCurrentSource()
            // Ready is not proof of a picture, so the layer gets the last word.
            watchForPicture(of: item)
        case .failed:
            isBuffering = false
            player.pause()
            // A loopback read can fail while the CDN still has the same bytes;
            // that is a source problem, not an item failure.
            if isPlayingProgressive, !isFallingBackFromProgressive {
                isFallingBackFromProgressive = true
                Task { [weak self] in await self?.fallbackFromProgressive() }
                return
            }
            // The Android original left the spinner turning forever here.
            enterTerminalState(.failed(.upstream(presentableFailure(item.error))))
        case .unknown:
            isBuffering = true
        @unknown default:
            isBuffering = true
        }
    }

    /// A download that will not play is worth naming: the user can re-queue or
    /// delete that copy from the Downloads screen.
    private func presentableFailure(_ error: (any Error)?) -> String {
        guard let error else {
            return isPlayingLocal
                ? "The downloaded copy could not be played."
                : "This video could not be played."
        }
        return isPlayingLocal
            ? "The downloaded copy could not be played: \(error.localizedDescription)"
            : error.localizedDescription
    }

    // MARK: - Source validation

    /// What the ready item's asset actually carries, measured once per rebuild.
    private struct SourceInspection: Sendable {
        let hasVideo: Bool
        /// The video track's sample entry (`hvc1`, `hev1`, `avc1`, …), when the
        /// track could be read. `hev1` is HEVC in the layout AVFoundation often
        /// does not render while its audio track still plays — but not always,
        /// so this is evidence for a message, never a rejection on its own.
        let videoCodec: String?
        let undecodableAudio: String?
    }

    /// Readiness is not proof of a picture: `AVPlayer` reports `.readyToPlay`
    /// for an audio-only asset, and for audio codecs it will render as noise.
    /// The asset's tracks are the evidence.
    private func inspectCurrentSource() {
        guard !isInspectingSource, let item, let asset = urlAsset else { return }
        isInspectingSource = true
        Task { [weak self] in
            let inspection = await Self.inspect(asset)
            guard let self, self.item === item else { return }
            // A verdict about an item that has since been replaced must not
            // clear the flag for the inspection the new item just started.
            self.isInspectingSource = false
            self.sourceInspected(inspection, for: item)
        }
    }

    private func sourceInspected(_ inspection: SourceInspection, for item: AVPlayerItem) {
        measuredInspection = inspection
        // Only a *missing* video track, or audio no device codec can render, is
        // proof of an unusable source. A `hev1` sample entry is not: the device
        // may well decode it, and rejecting on the container would dead-end a
        // title that plays. The picture watchdog is what catches the cases where
        // it does not, once the layer has had its say.
        guard inspection.hasVideo, inspection.undecodableAudio == nil else {
            Task { [weak self] in
                guard let self else { return }
                await self.recoverFromInvalidSource(inspection, item: item)
            }
            return
        }
    }

    /// The item is ready but unusable. Move to another source at the same
    /// clock; a black picture with sound behind it is never left playing.
    private func recoverFromInvalidSource(_ inspection: SourceInspection, item: AVPlayerItem) async {
        // A quality pick can replace the item between the verdict and this
        // task; only the item that was measured may be acted on.
        guard !stopped, self.item === item, !isRecoveringFromInvalidSource else { return }
        isRecoveringFromInvalidSource = true
        defer { isRecoveringFromInvalidSource = false }

        // Before giving up on the bytes, repair the one thing this device
        // provably cannot read: an `hev1` sample entry, which CoreMedia has no
        // codec type for. The container is otherwise the HEVC this device
        // decodes perfectly, so a failed source is often one label away from
        // playing.
        if await repairHEVCSource() { return }
        // The same repair for a file already on disk: patching its index is
        // four bytes of local I/O, not a re-fetch, and it is what makes a
        // downloaded copy playable with no connection at all.
        if await repairLocalHEVCSource() { return }

        if let url = currentSource?.url {
            unplayableSourceURLs.insert(PlaybackSourcePolicy.sourceKey(url))
        }
        let restart = livePosition

        if isPlayingLocal || isPlayingProgressive {
            // Reopening the same file would only reproduce the same failure;
            // the provider's copy is the next source. Both local paths have to
            // be skipped for this attempt, or load() would hand back the file
            // it just rejected. The download stays skipped afterwards because
            // `downloadedItem()` now sees its URL as unplayable; the flag is
            // restored so another episode can still use a good download.
            localRejection = Self.localSourceMessage(inspection, isDownload: isPlayingLocal)
            let wasIgnoringDownload = ignoresDownload
            let wasIgnoringProgressive = ignoresProgressive
            ignoresDownload = true
            ignoresProgressive = true
            await load(restartAt: restart)
            // Restore both flags: the rejected file is remembered in
            // `unplayableSourceURLs`, but the next episode may have a good
            // local copy. Leaving either flag set would disable that source for
            // the rest of the playback session.
            ignoresDownload = wasIgnoringDownload
            ignoresProgressive = wasIgnoringProgressive
            return
        }

        if let current = currentRendition,
           let next = PlaybackSourcePolicy.fallback(
               from: current,
               in: state.value?.streams ?? [],
               excluding: unplayableSourceURLs
           ),
           let url = next.urlValue {
            selectedRendition = next
            rebuild(.stream(next, url), startingAt: restart)
            return
        }

        // This payload held no other picture. A different language version is a
        // different upstream subject with its own bytes, so it is the next
        // source worth trying — and it is a source the viewer can also pick by
        // hand. Without this the player dead-ends on a title whose only stream
        // is audio-only, which is the black-picture-with-sound symptom.
        if let next = nextUntriedDub() {
            triedSourceIDs.insert(playbackSubjectID)
            selectedDub = next
            request = PlaybackRequest(
                subject: request.subject,
                season: request.season,
                episode: request.episode,
                resourceId: nil
            )
            await load(restartAt: restart)
            return
        }

        haltTerminalPlayback()
        enterTerminalState(.failed(.upstream(Self.invalidSourceMessage(inspection))))
    }

    /// Repairs an `hev1` source and restarts it, returning whether it did.
    ///
    /// `hev1` is HEVC the platform decodes, under a sample entry CoreMedia has no
    /// codec type for, so `AVPlayer` plays the sound and never draws a frame.
    /// Renaming the entry to `hvc1` is lossless when `hvcC` carries the
    /// parameter sets — which every provider file sampled does — and the
    /// repaired file is then the exact layout Apple asks for.
    ///
    /// Only the remote stream can be repaired: a downloaded or in-progress file
    /// is already on disk, and rewriting it in place would cost a full copy of
    /// the title for a fix the CDN copy gets for free.
    private func repairHEVCSource() async -> Bool {
        guard !isPlayingLocal, !isPlayingProgressive,
              case .stream(let rendition, let url) = currentSource,
              !repairedSourceURLs.contains(PlaybackSourcePolicy.sourceKey(url))
        else { return false }

        // One attempt per URL: a repaired source that still shows nothing is a
        // different failure, and retrying the repair would loop.
        repairedSourceURLs.insert(PlaybackSourcePolicy.sourceKey(url))
        let restart = livePosition

        guard let repaired = await HEVCRewrite().repairedFile(
            at: url,
            headers: MediaRequest.headers(cookie: rendition.cookie)
        ) else { return false }

        // The bytes are now local, and there is no second copy to fall back to:
        // `AVURLAsset` cannot be handed a URL without a file behind it.
        let file = URL.cachesDirectory
            .appendingPathComponent("HEVCRewrite", isDirectory: true)
            .appendingPathComponent("\(abs(url.absoluteString.hashValue)).mp4")
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try repaired.write(to: file, options: .atomic)
        } catch {
            return false
        }

        rebuild(.download(file), startingAt: restart)
        return true
    }

    /// Repairs the downloaded file this device refused to draw.
    ///
    /// The remote path re-fetches the title to rewrite its index; a file already
    /// on disk only needs four bytes patched, so this costs no network and no
    /// second copy. The download the viewer already paid for becomes playable,
    /// which is the difference between "offline" and the episode they saved.
    private func repairLocalHEVCSource() async -> Bool {
        guard isPlayingLocal,
              case .download(let fileURL) = currentSource,
              !repairedSourceURLs.contains(PlaybackSourcePolicy.sourceKey(fileURL))
        else { return false }

        // One attempt per file: a patched file that still shows nothing is a
        // different failure, and re-patching would loop.
        repairedSourceURLs.insert(PlaybackSourcePolicy.sourceKey(fileURL))
        let restart = livePosition
        let repaired = await Task.detached(priority: .userInitiated) {
            HEVCRewrite().repairInPlace(at: fileURL)
        }.value
        guard repaired else { return false }

        rebuild(.download(fileURL), startingAt: restart)
        return true
    }

    /// The next language version this session has not already proved pictureless,
    /// the original first: it is the one most likely to carry the video track a
    /// broken dub lacks, and it is what the viewer expects to fall back to.
    private func nextUntriedDub() -> Dub? {
        let tried = triedSourceIDs.union([playbackSubjectID])
        return request.subject.dubOptions
            .sorted { $0.isOriginal && !$1.isOriginal }
            .first { !tried.contains($0.subjectId) }
    }

    private nonisolated static func inspect(_ asset: AVURLAsset) async -> SourceInspection {
        let video: [AVAssetTrack]
        do {
            video = try await asset.loadTracks(withMediaType: .video)
        } catch {
            // A track load that failed says nothing about the picture; failing
            // playback on it would turn a transient read error into a dead end.
            return SourceInspection(hasVideo: true, videoCodec: nil, undecodableAudio: nil)
        }
        guard !video.isEmpty else {
            return SourceInspection(hasVideo: false, videoCodec: nil, undecodableAudio: nil)
        }

        // HEVC in an `hev1` sample entry is commonly not rendered by
        // AVFoundation, while its AAC track still plays. The provider serves
        // this layout, so inspect the actual sample entry rather than trusting
        // the existence of a video track.
        var videoCodec: String?
        if let formats = try? await video[0].load(.formatDescriptions),
           let format = formats.first {
            videoCodec = fourCharacterCode(CMFormatDescriptionGetMediaSubType(format))
                .trimmingCharacters(in: .whitespaces)
        }

        // Reject only when *every* audio track is unplayable. A supported main
        // track beside an unsupported alternate must not abandon the title;
        // that is what the audio-track picker is for.
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var firstUnsupportedAudio: String?
        for track in audio {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            if formats.isEmpty { continue }
            let playable = formats.contains { undecodableAudioCodec(in: $0) == nil }
            if !playable, firstUnsupportedAudio == nil,
               let format = formats.first,
               let codec = undecodableAudioCodec(in: format) {
                firstUnsupportedAudio = codec
            }
            if playable {
                firstUnsupportedAudio = nil
                break
            }
        }
        let hasAudio = !audio.isEmpty
        return SourceInspection(
            hasVideo: true,
            videoCodec: videoCodec,
            undecodableAudio: hasAudio ? firstUnsupportedAudio : nil
        )
    }

    private nonisolated static func undecodableAudioCodec(in format: CMFormatDescription) -> String? {
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let code = fourCharacterCode(subtype).lowercased()
        if undecodableAudioCodecs.contains(code) {
            return fourCharacterCode(subtype).trimmingCharacters(in: .whitespaces)
        }
        // Beyond 7.1 there is no downmix AVPlayer can render sensibly.
        if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           basic.mChannelsPerFrame > 8 {
            return "\(basic.mChannelsPerFrame) channels"
        }
        return nil
    }

    private nonisolated static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    /// Whether the provider call never produced an answer.
    private static func isTransportFailure(_ error: CinemacoreError) -> Bool {
        switch error {
        case .offline, .timedOut:
            true
        default:
            false
        }
    }

    /// What a rejected on-device copy means, in the viewer's terms.
    ///
    /// Only surfaced when the provider could not be asked either, so every
    /// sentence ends with the action that actually exists: delete the copy and
    /// fetch it again with a build that filters soundtracks out of the queue.
    private static func localSourceMessage(_ inspection: SourceInspection, isDownload: Bool) -> String {
        let copy = isDownload ? "downloaded copy" : "part-downloaded copy"
        if !inspection.hasVideo {
            return "The \(copy) has no video, so there is nothing to draw. Delete it in Downloads and download it again."
        }
        if let codec = inspection.undecodableAudio {
            return "The \(copy)'s audio (\(codec)) cannot be played on this device. Delete it in Downloads and download a different quality."
        }
        return "The \(copy) could not be drawn on this device, and the provider could not be reached. Delete it in Downloads and download it again."
    }

    private static func invalidSourceMessage(_ inspection: SourceInspection) -> String {
        if let codec = inspection.undecodableAudio {
            return "This title's audio (\(codec)) cannot be played on this device, and no other source is available."
        }
        // HEVC is named only when the track probe measured it, so the message
        // cannot blame a codec the source never carried. It does not claim the
        // device cannot decode HEVC — it can — only that this container was
        // served in a layout it will not draw and the repair did not land.
        if let codec = inspection.videoCodec, PlaybackSourcePolicy.isHEVC(codec: codec) {
            return "Every available source is HEVC in a format this device will not draw. No other source is available."
        }
        // The watchdog reaches here with a video track that exists but never
        // produced a frame, which is a different failure from a title that has
        // no video at all — and a different sentence.
        if inspection.hasVideo {
            return "This title's video could not be drawn on this device, and no other source is available."
        }
        return "This title has no video track, and no other source is available."
    }

    /// The player's own clock, which is fresher than the quarter-second tick.
    private var livePosition: Double? {
        let clock = player.currentTime().seconds
        if clock.isFinite, clock > 0 { return clock }
        if position > 0 { return position }
        return pendingSeek
    }

    private func playbackStateChanged() {
        let playing = player.rate != 0
        if playing != isPlaying {
            isPlaying = playing
            UIApplication.shared.isIdleTimerDisabled = playing
            publishNowPlaying()
        }
        isBuffering = item?.status != .readyToPlay
            || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if playing {
            if controlsVisible { scheduleAutoHide() }
        } else {
            controlsTask?.cancel()
        }
    }

    private func applyPendingSeek() {
        guard let pendingSeek else { return }
        self.pendingSeek = nil
        player.seek(
            to: CMTime(seconds: pendingSeek, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Transport

    func play() {
        player.play()
        // `rate` is the multiplier on top of "playing", so 1.0 needs no set.
        if speed != 1 { player.rate = Float(speed) }
        revealControls()
    }

    func pause() {
        player.pause()
        revealControls()
        controlsTask?.cancel()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seek on release only, which is what the scrub slider does; seeking per
    /// drag frame would thrash the demuxer.
    ///
    /// `revealingControls` is false for the double-tap skip, whose own indicator
    /// is the entire response.
    func seek(to seconds: Double, revealingControls: Bool = true) {
        guard duration > 0 else { return }
        let target = min(max(seconds, 0), duration)
        position = target
        pendingSeek = nil
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        refreshCue()
        publishNowPlaying()
        if revealingControls { revealControls() }
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
        showSkipIndicator(seconds)
    }

    /// Double-tapping a side of the picture skips like a d-pad would.
    func doubleTapped(forward: Bool) {
        guard !isLocked else { return }
        let seconds = forward ? 10.0 : -10
        seek(to: position + seconds, revealingControls: false)
        showSkipIndicator(seconds)
    }

    private func showSkipIndicator(_ seconds: Double) {
        let indicator = SkipIndicator(seconds: seconds)
        skipIndicator = indicator
        skipTask?.cancel()
        skipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled, self?.skipIndicator?.id == indicator.id else { return }
            self?.skipIndicator = nil
        }
    }

    /// Keeps the chrome alive through a drag: hiding the controls mid-scrub
    /// would tear down the slider the finger is holding.
    func beginScrubbing() {
        isScrubbing = true
        revealControls()
    }

    func endScrubbing() {
        isScrubbing = false
        revealControls()
    }

    // MARK: - Presentation

    /// Fullscreen is explicit state, so a rotation lock cannot leave the video
    /// in a letterbox the viewer has no way out of. The screen is what decides
    /// to follow a turned phone, and it does so through this: a derived rule
    /// inside the model would fight the button.
    ///
    /// `requestRotation` is false when the phone itself turned: the window is
    /// already landscape, so only the layout has to follow.
    func setFullscreen(_ value: Bool, requestRotation: Bool = true) {
        guard value != isFullscreen else { return }
        isFullscreen = value
        revealControls()
        PlayerOrientation.setFullscreen(value, requestRotation: requestRotation)
    }

    func toggleFullscreen() {
        setFullscreen(!isFullscreen)
    }

    /// One tap: hide now, or bring the overlay back and restart its timer.
    func toggleControls() {
        if controlsVisible {
            controlsTask?.cancel()
            controlsVisible = false
        } else {
            revealControls()
        }
    }

    /// A tap on the picture itself. While the lock owns the surface the tap only
    /// offers the way out, so a locked player cannot be closed or paused by a
    /// pocket.
    func surfaceTapped() {
        guard !isLocked else {
            revealUnlockHint()
            return
        }
        toggleControls()
    }

    func toggleLock() {
        isLocked.toggle()
        unlockTask?.cancel()
        unlockHintVisible = false
        if isLocked {
            controlsTask?.cancel()
            controlsVisible = false
        } else {
            revealControls()
        }
    }

    private func revealUnlockHint() {
        unlockHintVisible = true
        unlockTask?.cancel()
        unlockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.unlockHintVisible = false
        }
    }

    /// Shows the overlay and restarts its four seconds, which every control does
    /// after it acts so the timer cannot run out mid-interaction.
    private func revealControls() {
        guard !isLocked else { return }
        controlsVisible = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        controlsTask?.cancel()
        // Only while playing: a paused player keeps its controls, which is what
        // the Android build did and what a viewer expects.
        guard isPlaying, !isScrubbing, !isLocked else { return }
        controlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    // MARK: - Volume

    /// `revealsControls` is false for the edge-swipe: the level has its own
    /// readout on the picture, and flashing the whole chrome over a gesture the
    /// viewer is still making covers the film they are adjusting for.
    func setVolume(_ value: Double, revealsControls: Bool = true) {
        volume = min(max(value, 0), 1)
        isMuted = volume == 0
        player.volume = Float(volume)
        if revealsControls { revealControls() }
    }

    /// The left-edge swipe. Clamped just above zero: a black screen is not a
    /// setting anyone swiped for, it is a phone they cannot see.
    func setBrightness(_ value: Double) {
        let clamped = min(max(value, 0.02), 1)
        if brightnessBeforePlayback == nil {
            brightnessBeforePlayback = Double(UIScreen.main.brightness)
        }
        brightness = clamped
        UIScreen.main.brightness = CGFloat(clamped)
    }

    func toggleMute() {
        if isMuted || volume == 0 {
            // Unmuting restores the last audible level rather than jumping to
            // full, which is what a mute button means everywhere else.
            setVolume(lastAudibleVolume)
        } else {
            lastAudibleVolume = volume
            setVolume(0)
        }
    }

    // MARK: - Picture in picture

    /// The live layer, handed over once as the view builds it. Fullscreen only
    /// changes the layer's frame now, so PiP keeps the same surface.
    func attachSurface(_ layer: AVPlayerLayer) {
        pictureInPicture.attach(to: layer)
        guard surface !== layer else { return }
        surfaceObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in self?.pictureDidAppear() }
        }
    }

    /// A frame has been decoded and handed to the layer, which settles the
    /// question the track probe could not.
    private func pictureDidAppear() {
        pictureConfirmed = true
        pictureTask?.cancel()
        pictureTask = nil
    }

    /// Watches for the one failure the track probe cannot always see: a source
    /// that produces sound and never a frame.
    ///
    /// Armed on every ready item and disarmed the moment a picture appears, so
    /// it costs nothing on a healthy stream. The gate is `position > 0.5`, which
    /// is what separates "audio-only" from "still buffering" — a stalled stream
    /// must not be mistaken for a missing video track.
    private func watchForPicture(of item: AVPlayerItem) {
        pictureTask?.cancel()
        pictureConfirmed = surface?.isReadyForDisplay ?? false
        pictureTask = Task { [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self, self.item === item else { return }
                if self.pictureConfirmed { return }
                // `presentationSize` comes from the video track's own natural
                // size, so a non-zero value is independent evidence of a
                // picture even before the layer reports one.
                if self.item?.presentationSize != .zero { return }
                guard self.player.rate != 0, self.position > 0.5 else { continue }
                // The track probe already measured this asset; reuse its verdict
                // so the failure message names the codec that actually failed
                // instead of the generic "no video track".
                await self.recoverFromInvalidSource(
                    self.measuredInspection ?? SourceInspection(
                        hasVideo: false,
                        videoCodec: nil,
                        undecodableAudio: nil
                    ),
                    item: item
                )
                return
            }
        }
    }

    func stopPictureWatch() {
        pictureTask?.cancel()
        pictureTask = nil
        surfaceObservation?.invalidate()
        surfaceObservation = nil
        surface = nil
    }

    func togglePictureInPicture() {
        pictureInPicture.toggle()
    }

    /// The app is leaving the foreground. PiP is the one case where the video
    /// should keep playing; everywhere else the audio session must not keep
    /// talking over whatever the user switched to.
    ///
    /// Deliberately one-way: coming back does not resume, because the viewer
    /// may have left for a reason.
    func appDidLeaveForeground() {
        guard !isPiPActive else { return }
        pause()
    }

    // MARK: - Selection

    /// A dub is a separate upstream subject: switching means resolving that
    /// subject's streams, not selecting an audio track in this item.
    func selectDub(_ dub: Dub) async {
        guard dub != selectedDub else { return }
        let clock = livePosition
        selectedDub = dub
        // The viewer asked for these bytes deliberately, so a rejection earned
        // by an earlier language version does not stand in the way.
        triedSourceIDs.removeAll()
        // A mirror id belongs to the original subject; carrying it into a dub
        // request would name a resource that does not exist there.
        request = PlaybackRequest(
            subject: request.subject,
            season: request.season,
            episode: request.episode,
            resourceId: nil
        )
        selectedLanguage = request.subject.resourceDetectors.first
        await load(restartAt: clock)
    }

    func selectLanguage(_ language: ResourceDetector) async {
        guard language != selectedLanguage else { return }
        // The periodic observer only ticks four times a second; reading the
        // player's own clock keeps a mid-second switch from losing time.
        let clock = livePosition
        selectedLanguage = language
        request = PlaybackRequest(
            subject: request.subject,
            season: request.season,
            episode: request.episode,
            resourceId: language.resourceId
        )
        // Android restarted the new resource at the retained timestamp.
        await load(restartAt: clock)
    }

    /// Browsing only: the Android build deliberately left playback alone here.
    func selectSeason(_ number: Int) {
        selectedSeason = number
    }

    /// The caption overlay is drawn over the video, so swapping tracks leaves the
    /// player — and therefore the position — untouched.
    ///
    /// `subtitleChosen` is what keeps this pick through a provider response that
    /// lands afterwards; the two hydrate paths both check it before touching
    /// `selectedSubtitle`.
    func selectSubtitle(_ track: SubtitleTrack?) {
        subtitleChosen = true
        selectedSubtitle = track
        loadSubtitles()
        revealControls()
    }

    /// A different quality can be a different URL, which a bit-rate hint cannot
    /// reach: rebuilding at the live clock is the only way to honour the pick.
    /// When the URL is unchanged the hint is all a pick can mean, and the item
    /// is left alone so playback does not hitch.
    func selectQuality(_ rendition: StreamRendition) {
        revealControls()
        guard PlaybackSourcePolicy.isVideoCapable(rendition), let url = rendition.urlValue else { return }
        selectedRendition = rendition
        if let current = currentRendition, PlaybackSourcePolicy.sourceKey(current) == PlaybackSourcePolicy.sourceKey(rendition) {
            item?.preferredPeakBitRate = Self.bitrateHint(for: rendition)
            return
        }
        rebuild(.stream(rendition, url), startingAt: livePosition)
    }

    func setSpeed(_ value: Double) {
        speed = value
        // Assigning `rate` while paused would start playback, so a paused player
        // keeps the request and `play()` applies it.
        if isPlaying { player.rate = Float(value) }
        publishNowPlaying()
        // The library already has a field for this, so the choice survives the
        // screen rather than living in a `remember`-equivalent.
        Task { await app.updateSettings { $0.playbackSpeed = value } }
        revealControls()
    }

    /// A container-level audio choice: a media-selection change on the item in
    /// hand, so no refetch and no seek.
    func selectAudioTrack(_ track: AudioTrack) {
        guard let group = audioGroup else { return }
        // `appliesMediaSelectionCriteriaAutomatically` lives on the player, not
        // the item; leaving it on lets the system preference undo this pick.
        player.appliesMediaSelectionCriteriaAutomatically = false
        item?.select(track.option, in: group)
        selectedAudioTrack = track
        revealControls()
    }

    func selectEpisode(_ episode: Episode) async {
        request = PlaybackRequest(
            subject: request.subject,
            season: episode.season,
            episode: episode,
            resourceId: selectedLanguage?.resourceId
        )
        selectedSeason = episode.season
        // A new episode is a new file, so a source that had no picture for the
        // previous one is worth another look.
        triedSourceIDs.removeAll()
        await load()
    }

    func playNextEpisode() async {
        guard let next = nextEpisode else { return }
        await selectEpisode(next)
    }

    func playPreviousEpisode() async {
        guard let previous = previousEpisode else { return }
        await selectEpisode(previous)
    }

    private func itemDidPlayToEnd() async {
        guard app.settings.autoPlayNext, let next = nextEpisode else {
            revealControls()
            return
        }
        await selectEpisode(next)
    }

    // MARK: - Audio tracks

    /// The asset's own audio tracks, which are not the provider's dub variants
    /// in the language sheet.
    ///
    /// Only main-program tracks are exposed and auto-selected. A container may
    /// also carry descriptive narration, a commentary mix or an auxiliary
    /// stem; the system's default selection is free to choose one of those,
    /// which is how a film acquires a narrator it never had.
    private func loadAudioTracks() {
        audioTask?.cancel()
        audioGroup = nil
        audioTracks = []
        selectedAudioTrack = nil
        guard let asset = urlAsset else { return }

        audioTask = Task { [weak self] in
            let loaded = await Self.audibleGroup(of: asset)
            guard !Task.isCancelled, let self, let group = loaded.group else { return }

            let main = group.options.filter(Self.isMainProgramAudio)
            // Untagged containers exist; they still get a picker, just without
            // the accessibility/commentary tracks when those are identifiable.
            let eligible = main.isEmpty
                ? group.options.filter { !Self.isAuxiliaryAudio($0) }
                : main
            let options = eligible.isEmpty ? group.options : eligible
            // A mirror host name can never match an audio track; the chosen
            // language version is the meaningful hint.
            guard let chosen = Self.preferredAudioOption(
                in: options,
                languageName: self.selectedDub?.languageName ?? self.selectedLanguage?.name
            ) ?? options.first
            else { return }

            self.audioGroup = group
            // One main track is not a choice; the sheet stays away rather than
            // opening on a single row.
            self.audioTracks = options.count > 1 ? options.map(AudioTrack.init(option:)) : []
            self.selectedAudioTrack = AudioTrack(option: chosen)
            // Otherwise the system language preference can replace this choice
            // later, which is the default winning again by another route.
            self.player.appliesMediaSelectionCriteriaAutomatically = false
            self.item?.select(chosen, in: group)
        }
    }

    /// Main-program content is what a viewer means by "the audio"; the tag is
    /// advisory, so a container with none falls back to the audible options.
    private nonisolated static func isMainProgramAudio(_ option: AVMediaSelectionOption) -> Bool {
        option.mediaType == .audio
            && option.hasMediaCharacteristic(.isMainProgramContent)
            && !isAuxiliaryAudio(option)
    }

    /// Descriptive narration, commentary and alternate mixes: correct for the
    /// viewer who asked for them, wrong as an automatic default.
    private nonisolated static func isAuxiliaryAudio(_ option: AVMediaSelectionOption) -> Bool {
        guard option.mediaType == .audio else { return true }
        let label = option.displayName.lowercased()
        return option.hasMediaCharacteristic(.describesVideoForAccessibility)
            || option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
            || option.hasMediaCharacteristic(.isAuxiliaryContent)
            || label.contains("commentary")
            || label.contains("description")
            || label.contains("descriptive")
    }

    /// Prefers the track matching the provider resource the viewer chose, and
    /// otherwise the first main-program track.
    private nonisolated static func preferredAudioOption(
        in options: [AVMediaSelectionOption],
        languageName: String?
    ) -> AVMediaSelectionOption? {
        guard let languageName else { return options.first }
        let wanted = tokens(languageName)
        guard !wanted.isEmpty else { return options.first }
        return options.first { !wanted.isDisjoint(with: audioTokens(for: $0)) } ?? options.first
    }

    private nonisolated static func audioTokens(for option: AVMediaSelectionOption) -> Set<String> {
        var raw = [option.displayName]
        if let locale = option.locale {
            raw.append(locale.identifier)
            if let code = locale.language.languageCode?.identifier {
                raw.append(code)
                for identifier in ["en", "en_US"] {
                    if let name = Locale(identifier: identifier).localizedString(forLanguageCode: code) {
                        raw.append(name)
                    }
                }
            }
            if let name = Locale(identifier: "en_US").localizedString(forIdentifier: locale.identifier) {
                raw.append(name)
            }
        }
        return raw.reduce(into: Set<String>()) { $0.formUnion(tokens($1)) }
    }

    /// "English Dub", "en-US" and "English (Dolby 5.1)" have to meet on a
    /// common token; codec and channel words would only produce false matches.
    private nonisolated static func tokens(_ raw: String) -> Set<String> {
        let stopWords: Set<String> = [
            "dub", "dubbed", "sub", "subbed", "original", "audio", "track", "main",
            "program", "stereo", "surround", "aac", "ac3", "eac3", "default",
        ]
        return Set(
            raw.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 && !stopWords.contains($0) }
        )
    }

    /// Carries the group out of the loader's isolation.
    ///
    /// `AVMediaSelectionGroup` is not `Sendable`, but an option belongs to one
    /// asset and is only ever read here on the main actor; the box is what lets
    /// the load happen off the actor while saying so out loud.
    private struct AudibleGroup: @unchecked Sendable {
        let group: AVMediaSelectionGroup?
    }

    private nonisolated static func audibleGroup(of asset: AVURLAsset) async -> AudibleGroup {
        // `try?` because an asset with no audio at all is an answer, not a
        // failure worth surfacing.
        AudibleGroup(group: try? await asset.loadMediaSelectionGroup(for: .audible))
    }

    // MARK: - Position

    /// The Android build wrote history every second; five seconds is the same
    /// resume value without the write amplification.
    private func recordIfDue() {
        guard isPlaying, duration > 0 else { return }
        let now = Date()
        if let recordedAt, now.timeIntervalSince(recordedAt) < 5 { return }
        recordedAt = now
        record()
        // The same cadence corrects any drift the system's own extrapolation has
        // accumulated on the lock-screen scrubber.
        publishNowPlaying()
    }

    private func record() {
        // Without a duration the store would compute a 0% position and drop the
        // row, so an unmeasured item is not worth writing.
        guard duration > 0 else { return }
        let point = ResumePoint(
            subjectID: request.subject.id,
            title: request.title,
            poster: request.subject.poster,
            season: request.season,
            episode: request.episode?.number,
            positionSeconds: position,
            durationSeconds: duration
        )
        Task { await app.record(point) }
    }

    // MARK: - Now playing

    private func publishNowPlaying() {
        system.publish(PlayerSnapshot(
            title: request.episode?.displayTitle ?? request.subject.title,
            subtitle: nowPlayingSubtitle,
            duration: duration,
            position: position,
            rate: isPlaying ? speed : 0,
            isPlaying: isPlaying,
            hasNext: hasNextEpisode,
            hasPrevious: hasPreviousEpisode,
            artworkURL: request.subject.posterURL
        ))
    }

    // MARK: - Subtitles

    private func loadSubtitles() {
        subtitleTask?.cancel()
        document = nil
        activeCue = nil
        guard let track = selectedSubtitle, let url = URL(string: track.url) else { return }

        let headers = MediaRequest.headers(cookie: selectedRendition?.cookie)
        subtitleTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if url.isFileURL {
                    // A saved caption is already on disk. URLSession does not
                    // serve file URLs, and a network round trip is precisely
                    // what this track exists to avoid.
                    data = try Data(contentsOf: url)
                } else {
                    var request = URLRequest(url: url)
                    for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
                    data = try await URLSession.shared.data(for: request).0
                }
                guard !Task.isCancelled, let body = String(data: data, encoding: .utf8) else { return }
                // Converting and reading the track is disk work; keep it off the
                // main actor, which the player stack occupies.
                let cache = subtitleCache
                let webVTT = try await Task.detached(priority: .utility) {
                    let fileURL = try cache.prepare(track: track, contents: body)
                    return try String(contentsOf: fileURL, encoding: .utf8)
                }.value
                guard !Task.isCancelled else { return }
                self.document = SubtitleDocument(webVTT: webVTT)
                self.refreshCue()
            } catch {
                // A caption track that will not load must not stop the video; the
                // overlay simply stays empty.
                self.document = nil
                self.activeCue = nil
            }
        }
    }

    private func refreshCue() {
        let cue = document?.activeCue(at: position)
        if cue != activeCue { activeCue = cue }
    }

    // MARK: - Audio session

    /// `.playback` keeps video audio audible with the ring switch silenced, and
    /// `moviePlayback` matches the Android build's audio attributes.
    private func activateAudioSession() {
        // A session that cannot be configured still plays; it just follows the
        // silent switch, which is not worth failing playback over.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    /// Releasing the session lets whatever was playing before resume.
    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
