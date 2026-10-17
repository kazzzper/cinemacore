import AVFoundation
import CinemacoreCore
import Foundation
import Observation
import UIKit

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

    var isLocal: Bool {
        if case .download = self { return true }
        return false
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
    private var lastAudibleVolume = 1.0

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
        // The stored rate is a preference, not a contract: a document written by
        // another build could hold a speed this sheet cannot represent.
        let saved = app.settings.playbackSpeed
        speed = PlayInfo.speedOptions.contains(saved) ? saved : 1

        pictureInPicture.onChange = { [weak self] active in self?.isPiPActive = active }
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
    var subtitleLabel: String { selectedSubtitle?.language ?? "Off" }
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

    /// `mm:ss` with minutes uncapped, matching the Android player's clock.
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
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
        controlsTask?.cancel()
        subtitleTask?.cancel()
        audioTask?.cancel()
        skipTask?.cancel()
        unlockTask?.cancel()

        let clock = player.currentTime().seconds
        if clock.isFinite, clock > 0 { position = clock }
        record()

        player.pause()
        pictureInPicture.detach()
        system.stop()
        // Leaving fullscreen by leaving the screen still has to give the device
        // its orientation back.
        if isFullscreen { restorePortrait() }

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
                && $0.subjectID == request.subject.id
                && $0.season == request.season
                && $0.episode == request.episode?.number
        }
    }

    private func playStream(restartAt: Double?) async {
        do {
            let info = try await app.repository.playInfo(
                subjectID: request.subject.id,
                season: request.season,
                episode: request.episode?.number
            )
            await loadSeasons()
            // A resolve that lands after the screen is gone must not build an
            // item nobody can stop: `stop()` has already released the player.
            guard !stopped, !Task.isCancelled else { return }
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
            rebuild(.stream(stream, url), startingAt: await resume(restartAt))
        } catch {
            guard !stopped, !Task.isCancelled else { return }
            haltTerminalPlayback()
            state = error.requiresGate ? .locked(error) : .failed(error)
        }
    }

    /// Plays a finished download, then asks the provider only for what a file
    /// cannot carry: the caption tracks and the episode tree.
    private func playDownload(_ download: DownloadItem, restartAt: Double?) async {
        let url = app.localFileURL(for: download)
        // The rendition describes the provider's stream — which is what the
        // quality sheet names and what Download has to re-queue — while the file
        // travels in the source. Nothing here is ever handed to the player.
        let rendition = StreamRendition(
            quality: download.quality,
            url: download.remoteURL.absoluteString,
            size: download.sizeText,
            cookie: download.cookie
        )
        state = .loaded(PlayInfo(streams: [rendition], subtitles: []))
        selectedRendition = rendition
        selectedSubtitle = nil

        // Started before the metadata round trip, so a downloaded episode begins
        // instantly and plays with no connection whatsoever.
        rebuild(.download(url), startingAt: await resume(restartAt))
        await hydrateProviderMetadata()
    }

    /// The provider still owns the episode tree and the caption tracks, neither
    /// of which a downloaded file carries. Best effort by design: with no
    /// connection this returns having changed nothing, and playback continues.
    private func hydrateProviderMetadata() async {
        await loadSeasons()
        guard !stopped, !Task.isCancelled else { return }
        guard let info = try? await app.repository.playInfo(
            subjectID: request.subject.id,
            season: request.season,
            episode: request.episode?.number
        ), !info.isEmpty else { return }
        guard !stopped, !Task.isCancelled, case .loaded(let current) = state else { return }

        state = .loaded(PlayInfo(streams: current.streams, subtitles: info.subtitles))
        guard !subtitleChosen, selectedSubtitle == nil, !(selectedLanguage?.isDub ?? false),
              let first = info.subtitles.first else { return }
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

    /// The episode tree only drives the season/episode sheets and auto-advance.
    ///
    /// A failure here is deliberately non-fatal: playback does not depend on it,
    /// so those panels simply have nothing to offer.
    private func loadSeasons() async {
        guard isSeries, seasons.isEmpty else { return }
        let loaded = (try? await app.repository.seasons(subjectID: request.subject.id)) ?? []
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
        selectedRendition = info.preferredStream
        selectedSubtitle = (selectedLanguage?.isDub ?? false) ? nil : info.subtitles.first
    }

    private func rebuild(_ source: MediaSource, startingAt seconds: Double?) {
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
        }
        isPlayingLocal = source.isLocal

        let item = AVPlayerItem(asset: asset)
        // Keep the pitch natural at every sheet speed; without this, audio
        // sounds chipmunked above 1x.
        item.audioTimePitchAlgorithm = .timeDomain
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
            publishNowPlaying()
        case .failed:
            isBuffering = false
            player.pause()
            // The Android original left the spinner turning forever here.
            state = .failed(.upstream(presentableFailure(item.error)))
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

    /// Fullscreen is explicit state, never derived from the device orientation:
    /// with the rotation lock on, an orientation-derived rule would leave the
    /// video in a letterbox the user could not escape.
    func setFullscreen(_ value: Bool) {
        guard value != isFullscreen else { return }
        isFullscreen = value
        revealControls()
        if value {
            requestOrientation(.landscape)
        } else {
            restorePortrait()
        }
    }

    func toggleFullscreen() {
        setFullscreen(!isFullscreen)
    }

    /// A refusal is the expected answer under a rotation lock, so it is ignored:
    /// the state, not the device angle, is what fills the screen.
    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }

    /// Gives the device its portrait orientation back on the way out — but only
    /// while it is still landscape, so a user who rotated back by hand is left
    /// exactly where they put it.
    private func restorePortrait() {
        guard let scene = windowScene,
              scene.effectiveGeometry.interfaceOrientation.isLandscape else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }

    private var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
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

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        isMuted = volume == 0
        player.volume = Float(volume)
        revealControls()
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

    /// The live layer, handed over as the view builds it. Toggling fullscreen
    /// rebuilds that layer, so this is called more than once per screen.
    func attachSurface(_ layer: AVPlayerLayer) {
        pictureInPicture.attach(to: layer)
    }

    func togglePictureInPicture() {
        pictureInPicture.toggle()
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
        subtitleChosen = true
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
    /// in the language sheet. An asset with one audible track offers nothing to
    /// choose between, so the sheet stays away rather than opening empty.
    private func loadAudioTracks() {
        audioTask?.cancel()
        audioGroup = nil
        audioTracks = []
        selectedAudioTrack = nil
        guard let asset = urlAsset else { return }

        audioTask = Task { [weak self] in
            let group = await Self.audibleGroup(of: asset)
            guard !Task.isCancelled, let self, let group = group.group else { return }
            let options = group.options.map(AudioTrack.init(option:))
            guard options.count > 1 else { return }
            let current = self.item?.currentMediaSelection.selectedMediaOption(in: group)
            self.audioGroup = group
            self.audioTracks = options
            self.selectedAudioTrack = options.first { $0.option === current } ?? options.first
        }
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
