import AVFoundation
import CinemacoreCore
import Foundation
import Observation
import UIKit

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
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var activeCue: SubtitleCue?

    /// The episode (or movie) playing right now; an episode switch replaces it.
    private(set) var request: PlaybackRequest
    private(set) var seasons: [Season] = []
    private(set) var selectedSeason: Int
    private(set) var selectedLanguage: ResourceDetector?
    private(set) var selectedSubtitle: SubtitleTrack?
    private(set) var selectedRendition: StreamRendition?
    private(set) var speed = 1.0

    private let app: AppModel
    private let subtitleCache: SubtitleCache
    private var item: AVPlayerItem?
    private var document: SubtitleDocument?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var endTask: Task<Void, Never>?
    private var pendingSeek: Double?
    private var controlsTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var recordedAt: Date?
    private var stopped = false

    init(request: PlaybackRequest, app: AppModel) {
        self.request = request
        self.app = app
        selectedSeason = request.season ?? 1
        selectedLanguage = request.subject.resourceDetectors
            .first { $0.resourceId == request.resourceId }
            ?? request.subject.resourceDetectors.first

        subtitleCache = SubtitleCache(
            directory: URL.cachesDirectory.appendingPathComponent("Subtitles", isDirectory: true)
        )
    }

    // MARK: - Derived state

    var renditions: [StreamRendition] { state.value?.streams ?? [] }
    var subtitleTracks: [SubtitleTrack] { state.value?.subtitles ?? [] }
    var languages: [ResourceDetector] { request.subject.resourceDetectors }
    var isSeries: Bool { request.subject.isSeries }
    var playingEpisode: Episode? { request.episode }
    var seasonNumbers: [Int] { seasons.map(\.number) }

    var episodes: [Episode] {
        seasons.first { $0.number == selectedSeason }?.episodes ?? []
    }

    /// The episode after the one playing, across a season boundary.
    var nextEpisode: Episode? {
        guard isSeries, let current = request.episode else { return nil }
        let ordered = seasons.flatMap(\.episodes)
        guard let index = ordered.firstIndex(where: { $0.id == current.id }),
              ordered.indices.contains(index + 1) else { return nil }
        return ordered[index + 1]
    }

    var hasNextEpisode: Bool { nextEpisode != nil }
    var languageLabel: String { selectedLanguage?.name ?? "Default" }
    var subtitleLabel: String { selectedSubtitle?.language ?? "Off" }
    var qualityLabel: String { selectedRendition?.quality ?? "Auto" }
    var speedLabel: String { Self.speedText(speed) }

    /// `1.0` reads as "Normal" rather than "1.0x", matching the Android sheet.
    static func speedText(_ value: Double) -> String {
        guard value != 1 else { return "Normal" }
        return "\(value.formatted(.number.precision(.fractionLength(0...2))))x"
    }

    /// `mm:ss` with minutes uncapped, matching the Android player's clock.
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Lifecycle

    /// First appearance: claim the audio session, then resolve and play.
    func start() async {
        activateAudioSession()
        installTimeObserver()
        observePlaybackStatus()
        await load()
    }

    /// Last appearance: persist the position, release the player, and hand the
    /// audio session and the idle timer back to the system.
    func stop() {
        guard !stopped else { return }
        stopped = true
        controlsTask?.cancel()
        subtitleTask?.cancel()

        let clock = player.currentTime().seconds
        if clock.isFinite, clock > 0 { position = clock }
        record()

        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        playbackObservation?.invalidate()
        playbackObservation = nil
        endTask?.cancel()
        endTask = nil
        player.replaceCurrentItem(with: nil)
        UIApplication.shared.isIdleTimerDisabled = false
        deactivateAudioSession()
    }

    // MARK: - Loading

    /// Resolves play info and rebuilds the item.
    ///
    /// `restartAt` overrides where playback resumes; `nil` means "the position
    /// the library saved for this episode".
    func load(restartAt: Double? = nil) async {
        if state.value == nil { state = .loading } else { isReloading = true }
        defer { isReloading = false }

        do {
            let info = try await app.repository.playInfo(
                subjectID: request.subject.id,
                season: request.season,
                episode: request.episode?.number
            )
            await loadSeasons()
            guard !info.isEmpty else {
                haltTerminalPlayback()
                state = .empty
                return
            }
            state = .loaded(info)
            resetSelections(for: info)

            guard let stream = selectedRendition, let url = stream.urlValue else {
                haltTerminalPlayback()
                state = .empty
                return
            }
            let start: Double?
            if let restartAt {
                start = restartAt
            } else {
                start = await savedPosition()
            }
            rebuild(stream: stream, url: url, startingAt: start)
        } catch {
            haltTerminalPlayback()
            state = error.requiresGate ? .locked(error) : .failed(error)
        }
    }

    /// Stops the current item when the screen falls back to an error or empty
    /// state, so audio never plays behind a UI that no longer shows it.
    private func haltTerminalPlayback() {
        guard item != nil else { return }
        player.pause()
    }

    /// Re-resolves the stream after a failure.
    ///
    /// A failure mid-playback keeps the clock so the user does not lose their
    /// place; an initial failure falls back to the saved position.
    func retry() async {
        await load(restartAt: position > 0 ? position : nil)
    }

    /// The episode tree only drives the season/episode sheets and auto-advance.
    ///
    /// A failure here is deliberately non-fatal: playback does not depend on it,
    /// so those panels simply have nothing to offer.
    private func loadSeasons() async {
        guard isSeries, seasons.isEmpty else { return }
        seasons = (try? await app.repository.seasons(subjectID: request.subject.id)) ?? []
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
        selectedRendition = info.preferredStream
        selectedSubtitle = (selectedLanguage?.isDub ?? false) ? nil : info.subtitles.first
    }

    private func rebuild(stream: StreamRendition, url: URL, startingAt seconds: Double?) {
        let asset = AVURLAsset(url: url, options: [
            Self.headerFieldsKey: MediaRequest.headers(cookie: stream.cookie),
        ])
        let item = AVPlayerItem(asset: asset)
        // Keep the pitch natural at every sheet speed; without this, audio
        // sounds chipmunked above 1x.
        item.audioTimePitchAlgorithm = .timeDomain
        item.preferredPeakBitRate = Self.bitrateHint(for: stream)
        self.item = item
        pendingSeek = seconds
        observe(item)
        player.replaceCurrentItem(with: item)
        playbackStateChanged()
        loadSubtitles()
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

    /// A quality pick is a hint, never a different URL: the provider serves one
    /// URL for every rendition, so the choice becomes a peak-bit-rate ceiling
    /// for the adaptive ladder. `Auto` leaves it unlimited.
    private static func bitrateHint(for stream: StreamRendition) -> Double {
        switch stream.resolutionRank {
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
        case .failed:
            isBuffering = false
            player.pause()
            // The Android original left the spinner turning forever here.
            state = .failed(.upstream(item.error?.localizedDescription ?? "This video could not be played."))
        case .unknown:
            isBuffering = true
        @unknown default:
            isBuffering = true
        }
    }

    private func playbackStateChanged() {
        let playing = player.rate != 0
        if playing != isPlaying {
            isPlaying = playing
            UIApplication.shared.isIdleTimerDisabled = playing
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
    func seek(to seconds: Double) {
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
        revealControls()
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func beginScrubbing() {
        revealControls()
    }

    func toggleFullscreen() {
        isFullscreen.toggle()
        revealControls()
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

    /// Shows the overlay and restarts its four seconds, which every control does
    /// after it acts so the timer cannot run out mid-interaction.
    private func revealControls() {
        controlsVisible = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        controlsTask?.cancel()
        guard isPlaying else { return }
        controlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    // MARK: - Selection

    func selectLanguage(_ language: ResourceDetector) async {
        guard language != selectedLanguage else { return }
        selectedLanguage = language
        request = PlaybackRequest(
            subject: request.subject,
            season: request.season,
            episode: request.episode,
            resourceId: language.resourceId
        )
        // Android restarted the new resource at the retained timestamp.
        await load(restartAt: position > 0 ? position : nil)
    }

    /// Browsing only: the Android build deliberately left playback alone here.
    func selectSeason(_ number: Int) {
        selectedSeason = number
    }

    /// The caption overlay is drawn over the video, so swapping tracks leaves the
    /// player — and therefore the position — untouched.
    func selectSubtitle(_ track: SubtitleTrack?) {
        selectedSubtitle = track
        loadSubtitles()
        revealControls()
    }

    /// Local only: same URL, so nothing is refetched and nothing is seeked.
    func selectQuality(_ rendition: StreamRendition) {
        selectedRendition = rendition
        item?.preferredPeakBitRate = Self.bitrateHint(for: rendition)
        revealControls()
    }

    func setSpeed(_ value: Double) {
        speed = value
        // Assigning `rate` while paused would start playback, so a paused player
        // keeps the request and `play()` applies it.
        if isPlaying { player.rate = Float(value) }
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
        await load()
    }

    func playNextEpisode() async {
        guard let next = nextEpisode else { return }
        await selectEpisode(next)
    }

    private func itemDidPlayToEnd() async {
        guard app.settings.autoPlayNext, let next = nextEpisode else {
            revealControls()
            return
        }
        await selectEpisode(next)
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
                var request = URLRequest(url: url)
                for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
                let (data, _) = try await URLSession.shared.data(for: request)
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
