import CinemacoreCore
import SwiftUI

/// Playback surface: an `AVPlayer` with the app's own controls.
///
/// `AVKit`'s `VideoPlayer` is deliberately not used. Its chrome cannot express
/// the six selection sheets or the caption overlay, and it owns fullscreen in a
/// way that hides state the spec requires to be explicit.
struct PlayerScreen: View {
    let request: PlaybackRequest
    let app: AppModel

    @State private var model: PlayerModel
    @State private var sheet: PlayerSheet?
    @State private var scrubTarget: Double?
    @State private var downloadNotice: String?
    /// Fit versus fill is a viewing preference rather than a property of the
    /// media, so it outlives the screen — and the model, which is about
    /// transport, deliberately knows nothing about it.
    @AppStorage("player.videoFill") private var fillsScreen = false
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: PlaybackRequest, app: AppModel) {
        self.request = request
        self.app = app
        _model = State(initialValue: PlayerModel(request: request, app: app))
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            if model.state.value == nil {
                failureState
            } else if model.isFullscreen {
                playerBox
            } else {
                VStack(spacing: 0) {
                    playerBox
                    ScrollView { details }
                        .scrollIndicators(.hidden)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.unlockHintVisible)
        // The overlay owns every exit: an empty navigation bar above a video is
        // chrome for nothing.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Fullscreen takes the system bars with it — including the home
        // indicator, which is why this is not just a status-bar flag.
        .statusBarHidden(model.isFullscreen)
        .persistentSystemOverlays(model.isFullscreen ? .hidden : .automatic)
        .sheet(item: $sheet) { sheetContent($0) }
        .alert("Download", isPresented: noticeIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadNotice ?? "")
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        // The pill is the only feedback a double-tap skip has, so it has to
        // reach a viewer who cannot see it.
        .onChange(of: model.skipIndicator) { _, indicator in
            guard let indicator else { return }
            AccessibilityNotification.Announcement(
                "Skipped \(indicator.isForward ? "forward" : "back") \(Int(abs(indicator.seconds))) seconds"
            ).post()
        }
    }

    // MARK: - States

    private var failureState: some View {
        StateView(
            state: model.state,
            emptyTitle: "No stream available",
            emptyMessage: "The provider returned no playable source for this title.",
            emptyIcon: "film.slash",
            retry: { await model.retry() }
        ) { _ in EmptyView() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Layout.spacing3) {
            Text(model.request.title)
                .font(Typography.sectionTitle)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(2)

            ScrollView(.horizontal) {
                HStack(spacing: Layout.spacing2) {
                    if let episode = model.playingEpisode {
                        Chip(text: "S\(episode.season) E\(episode.number)")
                    }
                    if model.isPlayingLocal { Chip(text: "Downloaded", prominent: true) }
                    if model.languages.count > 1 { Chip(text: model.languageLabel) }
                    Chip(text: model.qualityLabel)
                    if model.speed != 1 { Chip(text: model.speedLabel) }
                    if let subtitle = model.selectedSubtitle { Chip(text: subtitle.language) }
                }
            }
            .scrollIndicators(.hidden)

            // The 16:9 box on a phone cannot hold a second row of 44pt targets,
            // so everything about the session rather than the transport sits
            // here instead of disappearing.
            utilityRow
        }
        .padding(Layout.spacing4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Video

    @ViewBuilder
    private var playerBox: some View {
        // Fullscreen drops the 16:9 constraint and takes every point offered;
        // portrait fits the frame to the width.
        playerSurface()
            .aspectRatio(model.isFullscreen ? nil : 16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: model.isFullscreen ? .infinity : nil)
    }

    private func playerSurface() -> some View {
        ZStack {
            videoLayer
                .contentShape(Rectangle())

            gestureLayer

            if model.isBuffering || model.isReloading {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.textPrimary.color)
                    .allowsHitTesting(false)
            }

            captionOverlay

            if model.controlsVisible {
                // The scrim is decoration only: letting it take hit tests would
                // swallow the tap that is supposed to hide the overlay.
                controlsScrim
                    .allowsHitTesting(false)
                controls
            }

            skipPill
            unlockControl
        }
        .background(Color.black)
    }

    /// Only fullscreen drops the safe area, and this branch is the only way to
    /// do that — so the layer is rebuilt whenever fullscreen changes, which is
    /// why picture-in-picture adopts whichever layer it is last handed.
    @ViewBuilder
    private var videoLayer: some View {
        if model.isFullscreen {
            PlayerLayerView(
                player: model.player,
                fillsScreen: fillsScreen,
                onLayerReady: { model.attachSurface($0) }
            )
            .ignoresSafeArea()
        } else {
            PlayerLayerView(
                player: model.player,
                fillsScreen: fillsScreen,
                onLayerReady: { model.attachSurface($0) }
            )
        }
    }

    /// The picture's own gestures: a tap toggles the chrome, a double tap skips
    /// one side ten seconds, and a downward swipe leaves fullscreen.
    ///
    /// Split into halves rather than measured: SwiftUI already knows which side
    /// was tapped, and two halves cannot disagree with the layout.
    private var gestureLayer: some View {
        HStack(spacing: 0) {
            tapHalf(forward: false)
            tapHalf(forward: true)
        }
        .simultaneousGesture(exitSwipe)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Video")
        .accessibilityHint("Toggles the controls. Double-tap a side to skip ten seconds.")
        .accessibilityAction { model.surfaceTapped() }
    }

    private func tapHalf(forward: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            // Declared ahead of the single tap so SwiftUI holds that one back
            // for the double-tap window instead of firing both.
            .onTapGesture(count: 2) { model.doubleTapped(forward: forward) }
            .onTapGesture { model.surfaceTapped() }
    }

    /// Downward only: an upward swipe is a scroll everywhere else in iOS, and a
    /// horizontal one belongs to the scrubber.
    private var exitSwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard model.isFullscreen, !model.isLocked else { return }
                let offset = value.translation
                guard offset.height > 60, abs(offset.height) > abs(offset.width) else { return }
                model.setFullscreen(false)
            }
    }

    private var controlsScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.6), .black.opacity(0.1), .black.opacity(0.7)],
            startPoint: .top,
            endPoint: .bottom
        )
        .transition(.opacity)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var captionOverlay: some View {
        if let cue = model.activeCue {
            Text(cue.text)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Layout.spacing3)
                .padding(.vertical, 6)
                .background(
                    .black.opacity(0.62),
                    in: RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous)
                )
                .padding(.horizontal, Layout.spacing4)
                .padding(.bottom, model.controlsVisible ? 96 : Layout.spacing4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }

    /// Without this the only evidence of a double-tap skip is the moving
    /// scrubber, which the finger is usually covering.
    @ViewBuilder
    private var skipPill: some View {
        if let indicator = model.skipIndicator {
            HStack(spacing: Layout.spacing2) {
                Image(systemName: indicator.isForward ? "goforward" : "gobackward")
                Text(indicator.text)
            }
            .font(Typography.rowTitle)
            .foregroundStyle(theme.textPrimary.color)
            .padding(.horizontal, Layout.spacing4)
            .padding(.vertical, Layout.spacing2)
            .background(.black.opacity(0.55), in: Capsule())
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: indicator.isForward ? .trailing : .leading
            )
            .padding(.horizontal, Layout.spacing6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// The only affordance the lock leaves behind: shown by a tap, gone again in
    /// three seconds, so a lock cannot be left unlocked by accident.
    @ViewBuilder
    private var unlockControl: some View {
        if model.isLocked, model.unlockHintVisible {
            Button { model.toggleLock() } label: {
                Label("Unlock", systemImage: "lock.fill")
                    .font(Typography.button)
                    .foregroundStyle(theme.textPrimary.color)
                    .padding(.horizontal, Layout.spacing4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(minHeight: Layout.minimumTarget)
            }
            .accessibilityLabel("Unlock playback controls")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(Layout.spacing4)
            .transition(.opacity)
        }
    }

    // MARK: - Chrome

    private var controls: some View {
        VStack(spacing: Layout.spacing2) {
            topRow
            Spacer(minLength: 0)
            transportRow
            scrubberRow
            if model.isFullscreen { utilityRow }
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing3)
        .transition(.opacity)
    }

    private var topRow: some View {
        HStack(spacing: Layout.spacing2) {
            iconButton("xmark", label: "Close player") { dismiss() }
            if model.isPlayingLocal { downloadedBadge }
            Spacer(minLength: 0)
            if model.speed != 1 { Chip(text: model.speedLabel, prominent: true) }
            settingsMenu
            iconButton("arrow.down.circle", label: "Download this \(model.isSeries ? "episode" : "movie")") {
                Task { await queueDownload() }
            }
            iconButton(
                model.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: model.isFullscreen ? "Exit fullscreen" : "Enter fullscreen"
            ) {
                model.toggleFullscreen()
            }
        }
    }

    /// The badge that says these bytes are on the device, which is the promise
    /// the Downloads screen makes.
    private var downloadedBadge: some View {
        HStack(spacing: Layout.spacing1) {
            Image(systemName: "arrow.down.circle.fill")
            Text("Downloaded")
        }
        .font(Typography.badge)
        .foregroundStyle(theme.textPrimary.color)
        .padding(.horizontal, Layout.spacing2)
        .padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Playing a downloaded copy from this device")
    }

    private var transportRow: some View {
        HStack(spacing: Layout.spacing5) {
            if model.isSeries { episodeButton(previous: true) }
            iconButton("gobackward.10", label: "Skip back 10 seconds", size: 24) {
                model.skip(by: -10)
            }

            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(theme.textPrimary.color)
                    .frame(width: 60, height: Layout.minimumTarget)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            iconButton("goforward.10", label: "Skip forward 10 seconds", size: 24) {
                model.skip(by: 10)
            }
            if model.isSeries { episodeButton(previous: false) }
        }
    }

    /// Present at both ends of a series and disabled there, so the row does not
    /// reflow as the viewer moves through a season.
    private func episodeButton(previous: Bool) -> some View {
        let available = previous ? model.hasPreviousEpisode : model.hasNextEpisode
        return iconButton(
            previous ? "backward.end.fill" : "forward.end.fill",
            label: previous ? "Previous episode" : "Next episode",
            size: 22
        ) {
            Task {
                if previous {
                    await model.playPreviousEpisode()
                } else {
                    await model.playNextEpisode()
                }
            }
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.35)
    }

    private var scrubberRow: some View {
        HStack(spacing: Layout.spacing3) {
            Text(PlayerModel.timeText(scrubTarget ?? model.position))
                .font(Typography.metadata.monospacedDigit())
                .foregroundStyle(theme.textPrimary.color)

            Slider(
                value: Binding(
                    get: { scrubTarget ?? model.position },
                    set: { scrubTarget = $0 }
                ),
                in: 0...max(model.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        model.beginScrubbing()
                        scrubTarget = model.position
                    } else {
                        // Seeking happens here, on release, never per drag frame.
                        let target = scrubTarget ?? model.position
                        scrubTarget = nil
                        model.seek(to: target)
                        model.endScrubbing()
                    }
                }
            )
            .tint(theme.brand.color)
            .accessibilityLabel("Playback position")
            .accessibilityValue(PlayerModel.timeText(scrubTarget ?? model.position))

            Text(PlayerModel.remainingText(position: scrubTarget ?? model.position, duration: model.duration))
                .font(Typography.metadata.monospacedDigit())
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    /// Everything about the session rather than the transport. In fullscreen it
    /// sits under the scrubber; in portrait the same row lives below the picture.
    private var utilityRow: some View {
        HStack(spacing: Layout.spacing2) {
            iconButton(model.volumeSymbol, label: model.isMuted ? "Unmute" : "Mute") {
                model.toggleMute()
            }

            Slider(
                value: Binding(get: { model.volume }, set: { model.setVolume($0) }),
                in: 0...1
            )
            .tint(theme.textPrimary.color)
            .frame(maxWidth: 160)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((model.volume * 100).rounded())) percent")

            Spacer(minLength: Layout.spacing2)

            iconButton(
                fillsScreen ? "aspectratio.fill" : "aspectratio",
                label: fillsScreen ? "Fit the whole frame on screen" : "Fill the screen with video"
            ) {
                fillsScreen.toggle()
            }
            if PictureInPicture.isSupported {
                iconButton(
                    model.isPiPActive ? "pip.exit" : "pip.enter",
                    label: model.isPiPActive ? "Leave picture in picture" : "Picture in picture"
                ) {
                    model.togglePictureInPicture()
                }
                .disabled(!model.canStartPictureInPicture)
                .opacity(model.canStartPictureInPicture ? 1 : 0.35)
            }
            AirPlayRoutePicker(tint: theme.textPrimary.color)
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
                .accessibilityLabel("AirPlay")
            iconButton(
                model.isLocked ? "lock.fill" : "lock.open",
                label: model.isLocked ? "Unlock controls" : "Lock controls"
            ) {
                model.toggleLock()
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            if !model.languages.isEmpty {
                Button("Audio · \(model.languageLabel)") { sheet = .language }
            }
            // Only when the container actually carries a choice: an empty sheet
            // is worse than no row at all.
            if model.audioTracks.count > 1 {
                Button("Track · \(model.selectedAudioTrack?.label ?? "Default")") { sheet = .audio }
            }
            if model.isSeries {
                Button("Season · \(model.selectedSeason)") { sheet = .season }
            }
            Button("Subtitles · \(model.subtitleLabel)") { sheet = .subtitle }
            if !model.renditions.isEmpty {
                Button("Quality · \(model.qualityLabel)") { sheet = .quality }
            }
            Button("Speed · \(model.speedLabel)") { sheet = .speed }
            if model.isSeries, !model.episodes.isEmpty {
                Button("Episodes") { sheet = .episodes }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.headline)
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
        }
        .accessibilityLabel("Playback settings")
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        size: CGFloat = 20,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
        }
        .accessibilityLabel(label)
    }

    // MARK: - Downloads

    /// Queues the rendition that is actually playing.
    ///
    /// The player holds the resolved stream, so it hands it over rather than
    /// asking the provider again — a second resolve could return a URL the user
    /// never selected.
    private func queueDownload() async {
        guard let rendition = model.selectedRendition else {
            downloadNotice = "There is no stream to download yet."
            return
        }
        let outcome = await app.enqueueDownload(
            subject: model.request.subject,
            target: DownloadTarget(
                season: model.request.season,
                episode: model.request.episode
            ),
            rendition: rendition
        )
        downloadNotice = outcome.message
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { downloadNotice != nil },
            set: { if !$0 { downloadNotice = nil } }
        )
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .language:
            SelectionSheet(
                title: "Audio",
                items: model.languages,
                label: \.name,
                isSelected: { $0 == model.selectedLanguage },
                onSelect: { language in Task { await model.selectLanguage(language) } }
            )

        case .audio:
            SelectionSheet(
                title: "Audio Track",
                items: model.audioTracks,
                label: \.label,
                isSelected: { $0 == model.selectedAudioTrack },
                onSelect: { model.selectAudioTrack($0) }
            )

        case .season:
            SelectionSheet(
                title: "Season",
                items: model.seasonNumbers,
                label: { "Season \($0)" },
                isSelected: { $0 == model.selectedSeason },
                onSelect: { model.selectSeason($0) }
            )

        case .subtitle:
            SelectionSheet(
                title: "Subtitles",
                items: model.subtitleTracks,
                label: \.language,
                isSelected: { $0 == model.selectedSubtitle },
                onSelect: { model.selectSubtitle($0) },
                noneLabel: "Off",
                isNoneSelected: model.selectedSubtitle == nil,
                onSelectNone: { model.selectSubtitle(nil) }
            )

        case .quality:
            SelectionSheet(
                title: "Video Quality",
                items: model.renditions,
                label: \.quality,
                isSelected: { $0 == model.selectedRendition },
                onSelect: { model.selectQuality($0) },
                detail: { $0.size }
            )

        case .speed:
            SelectionSheet(
                title: "Playback Speed",
                items: PlayInfo.speedOptions,
                label: PlayerModel.speedText,
                isSelected: { $0 == model.speed },
                onSelect: { model.setSpeed($0) }
            )

        case .episodes:
            SelectionSheet(
                title: "Episodes",
                items: model.episodes,
                label: { String(format: "%02d", $0.number) },
                isSelected: { $0.id == model.playingEpisode?.id },
                onSelect: { episode in Task { await model.selectEpisode(episode) } },
                columns: 4
            )
        }
    }
}

/// The selection panels reachable from the controls.
private enum PlayerSheet: String, Identifiable {
    case language, audio, season, subtitle, quality, speed, episodes

    var id: String { rawValue }
}
