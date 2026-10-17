import AVFoundation
import AVKit
import MediaPlayer
import UIKit

/// What the system surfaces need in order to draw the now-playing card.
///
/// Taken as one value so a single publish cannot mix fields from two moments —
/// the previous episode's title with the new episode's duration.
struct PlayerSnapshot: Sendable {
    let title: String
    /// The line under the title: which episode of which show.
    let subtitle: String?
    let duration: Double
    let position: Double
    /// The live multiplier, so the lock-screen scrubber advances at 2x too.
    let rate: Double
    let isPlaying: Bool
    let hasNext: Bool
    let hasPrevious: Bool
    let artworkURL: URL?
}

/// The lock screen / Control Center card, and the commands those surfaces send
/// back.
///
/// A separate object because none of this is player state: it is a projection of
/// the player onto surfaces the app does not own, and it has to be able to
/// disappear without touching the playback stack.
@MainActor
final class NowPlayingBridge {
    private weak var model: PlayerModel?
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    private var last: PlayerSnapshot?
    private var artwork: MPMediaItemArtwork?
    private var artworkURL: URL?
    private var artworkTask: Task<Void, Never>?

    /// Installs the remote commands exactly once. The player screen can be
    /// pushed again after a pop, and a second set of targets would run every
    /// command twice.
    func attach(to model: PlayerModel) {
        self.model = model
        guard targets.isEmpty else { return }
        installCommands()
    }

    // MARK: - Publishing

    func publish(_ snapshot: PlayerSnapshot) {
        last = snapshot
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
        ]
        if let subtitle = snapshot.subtitle { info[MPMediaItemPropertyAlbumTitle] = subtitle }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // `playbackState` is what lets the system extrapolate the elapsed time
        // from the rate between our updates, so the scrubber keeps tracking
        // instead of snapping back on every poll.
        MPNowPlayingInfoCenter.default().playbackState = snapshot.isPlaying ? .playing : .paused
        updateAvailability(snapshot)
        loadArtwork(snapshot.artworkURL)
    }

    func stop() {
        for (command, token) in targets { command.removeTarget(token) }
        targets = []
        artworkTask?.cancel()
        artworkTask = nil
        artwork = nil
        artworkURL = nil
        last = nil
        model = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func updateAvailability(_ snapshot: PlayerSnapshot) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = snapshot.hasNext
        center.previousTrackCommand.isEnabled = snapshot.hasPrevious
    }

    /// Poster art is fetched once per title and handed over already decoded: the
    /// system asks for sizes on its own schedule and must never be made to wait
    /// on the network.
    private func loadArtwork(_ url: URL?) {
        guard let url, url != artworkURL else { return }
        artworkURL = url
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            guard !Task.isCancelled, let self else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            if let last = self.last { self.publish(last) }
        }
    }

    // MARK: - Commands

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { model, _ in
            model.play()
            return .success
        }
        add(center.pauseCommand) { model, _ in
            model.pause()
            return .success
        }
        add(center.togglePlayPauseCommand) { model, _ in
            model.togglePlayback()
            return .success
        }
        add(center.changePlaybackPositionCommand) { model, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            model.seek(to: event.positionTime)
            return .success
        }
        add(center.skipForwardCommand) { model, event in
            model.skip(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? 10)
            return .success
        }
        add(center.skipBackwardCommand) { model, event in
            model.skip(by: -((event as? MPSkipIntervalCommandEvent)?.interval ?? 10))
            return .success
        }
        add(center.nextTrackCommand) { model, _ in
            guard model.hasNextEpisode else { return .noSuchContent }
            Task { await model.playNextEpisode() }
            return .success
        }
        add(center.previousTrackCommand) { model, _ in
            guard model.hasPreviousEpisode else { return .noSuchContent }
            Task { await model.playPreviousEpisode() }
            return .success
        }

        // The intervals the system offers (headphone double-tap, CarPlay) match
        // the on-screen buttons rather than some other player's default.
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    /// MediaPlayer does not promise which thread delivers a command, and the
    /// handler has to answer synchronously, so a call that is not on the main
    /// actor is refused rather than raced.
    private func add(
        _ command: MPRemoteCommand,
        _ action: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget { [weak self] event in
            guard let self, let model = self.model, Thread.isMainThread else { return .commandFailed }
            return MainActor.assumeIsolated { action(model, event) }
        }
        command.isEnabled = true
        targets.append((command, token))
    }
}

/// Picture-in-picture over the on-screen player layer.
///
/// `AVPictureInPictureController` is not main-actor annotated, but every value
/// it touches here is; the delegate callbacks are the only way in from outside
/// and hop before touching anything.
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    /// iPhone support arrived in iOS 14, so the check is still worth making.
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Called whenever a session starts or stops, so the chrome can follow.
    var onChange: ((Bool) -> Void)?

    private var controller: AVPictureInPictureController?

    /// Adopts `layer`, replacing any layer adopted before it.
    ///
    /// Toggling fullscreen rebuilds the video layer, so this is called more than
    /// once per screen: the controller has to follow the layer that is on
    /// screen, not the first one it ever saw.
    func attach(to layer: AVPlayerLayer) {
        guard Self.isSupported, controller?.playerLayer !== layer else { return }
        controller?.delegate = nil
        let source = AVPictureInPictureController.ContentSource(playerLayer: layer)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Leaving the app is exactly when PiP is wanted.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
    }

    func detach() {
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
    }

    /// A no-op while the system has not yet made PiP possible, which is the same
    /// condition the disabled chrome button shows.
    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    // MARK: - Delegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.note(active: true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in self.note(active: false) }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        Task { @MainActor in self.note(active: false) }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The player screen is still mounted behind the PiP window, so there is
        // no interface to rebuild — the system only has to bring the app back.
        completionHandler(true)
    }

    private func note(active: Bool) {
        onChange?(active)
    }
}
