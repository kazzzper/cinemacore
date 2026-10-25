import CinemacoreCore
import SwiftUI

/// Playback surface: an `AVPlayer` with the app's own controls.
///
/// `AVKit`'s `VideoPlayer` is deliberately not used. Its chrome cannot express
/// the playback option sheet or the caption overlay, and it owns fullscreen in a
/// way that hides state the spec requires to be explicit.
struct PlayerScreen: View {
    let request: PlaybackRequest
    let app: AppModel

    @State private var model: PlayerModel
    @State private var showsOptions = false
    @State private var scrubTarget: Double?
    @State private var downloadNotice: String?
    /// Set by the sheet's Download row, consumed when the sheet has finished
    /// dismissing: an alert cannot be presented over a sheet.
    @State private var pendingDownload = false
    /// The level an edge drag is moving, and the value it is at. Held here so
    /// the readout can animate away after the finger lifts without the model
    /// knowing anything about gestures.
    @State private var levelHUD: LevelHUD?
    @State private var levelDrag: LevelDrag?
    @State private var levelHideTask: Task<Void, Never>?
    /// Fit versus fill is a viewing preference rather than a property of the
    /// media, so it outlives the screen — and the model, which is about
    /// transport, deliberately knows nothing about it.
    @AppStorage("player.videoFill") private var fillsScreen = false
    /// Landscape puts the notch over the picture on a notched iPhone. Full bleed
    /// stays the default — it is the only way to use every pixel — so this opts
    /// *in* to pulling the picture back inside the safe area.
    @AppStorage("player.avoidNotch") private var avoidsNotch = false
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// A phone held sideways is the player's wide layout. Without this the
    /// screen stays portrait-shaped in landscape, and the 16:9 box sharing the
    /// stack with the details scroll squeezes the picture into a thin band.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// True while fullscreen came from turning the phone rather than from the
    /// button, so turning it back can undo that and nothing else.
    @State private var fullscreenFromRotation = false

    init(request: PlaybackRequest, app: AppModel) {
        self.request = request
        self.app = app
        _model = State(initialValue: PlayerModel(request: request, app: app))
    }

    /// The two levels an edge swipe can move.
    private struct LevelHUD: Equatable {
        enum Kind { case volume, brightness }
        let kind: Kind
        let value: Double
    }

    /// Where a level drag started, so a second swipe continues from the level
    /// the first one left rather than from where it began.
    private struct LevelDrag: Equatable {
        let kind: LevelHUD.Kind
        let start: Double
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            if model.state.value == nil {
                failureState
            } else {
                // One player surface in one container, whichever mode is active.
                // Branching between a bare `playerBox` and a `VStack` moved the
                // surface in the view tree, which rebuilt `PlayerLayerView` —
                // and with it the `AVPlayerLayer` and its PiP controller — on
                // every fullscreen toggle.
                VStack(spacing: 0) {
                    playerBox
                    if !model.isFullscreen {
                        ScrollView { details }
                            .scrollIndicators(.hidden)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.unlockHintVisible)
        // The overlay owns every exit: an empty navigation bar above a video is
        // chrome for nothing.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // The player owns the screen while it is up: the tab bar both steals
        // height from the portrait layout and has no business in fullscreen.
        .toolbar(.hidden, for: .tabBar)
        // Fullscreen takes the system bars with it — including the home
        // indicator, which is why this is not just a status-bar flag.
        .statusBarHidden(model.isFullscreen)
        .persistentSystemOverlays(model.isFullscreen ? .hidden : .automatic)
        .sheet(isPresented: $showsOptions, onDismiss: downloadAfterOptions) {
            PlayerOptionsSheet(
                model: model,
                fillsScreen: $fillsScreen,
                avoidsNotch: $avoidsNotch,
                download: { pendingDownload = true }
            )
        }
        .alert("Download", isPresented: noticeIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadNotice ?? "")
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
        // The rotation the viewer performed is the only request needed: asking
        // for it again would fight a window that is already landscape.
        // `initial` so a player opened while the phone is already sideways
        // starts in the wide layout instead of the portrait one.
        .onChange(of: verticalSizeClass, initial: true) { _, size in
            if size == .compact, !model.isFullscreen {
                fullscreenFromRotation = true
                model.setFullscreen(true, requestRotation: false)
            } else if size == .regular, fullscreenFromRotation {
                fullscreenFromRotation = false
                model.setFullscreen(false, requestRotation: false)
            }
        }
        // `.inactive` as well as `.background`: the app is no longer the thing
        // the viewer is watching, and PiP is the only carrier that should keep
        // the picture alive.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background: model.appDidLeaveForeground()
            case .active: break
            @unknown default: break
            }
        }
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
            retry: { await model.retry() },
            returnTitle: "Back to details",
            // The player hides the navigation bar and owns every exit, so a
            // failed screen without this button would be a dead end: the only
            // control left is "Try Again", which cannot fix an unsupported
            // codec or an empty payload.
            returnAction: { dismiss() }
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
                    if model.dubOptions.count > 1 { Chip(text: model.dubLabel) }
                    Chip(text: model.qualityLabel)
                    if model.speed != 1 { Chip(text: model.speedLabel) }
                    if let subtitle = model.selectedSubtitle { Chip(text: subtitle.language) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(Layout.spacing4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Video

    private var playerBox: some View {
        // Fullscreen drops the 16:9 constraint and takes every point offered;
        // portrait fits the frame to the width.
        playerSurface()
            .aspectRatio(model.isFullscreen ? nil : 16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: model.isFullscreen ? .infinity : nil)
    }

    /// The stage keeps the chrome inside the safe area; only ``surfaceCanvas``
    /// leaves it. That is what lets fullscreen fill the display without putting
    /// a button under the notch or the home indicator.
    ///
    /// A `web`-kind rendition has no media chrome: the embed page owns the
    /// clock, the quality and the captions, so only the web view is rendered
    /// and none of the `AVPlayer` overlay machinery is put on top of it.
    @ViewBuilder
    private func playerSurface() -> some View {
        if let url = model.webStreamURL {
            WebStreamView(url: url)
                .accessibilityLabel("Web player")
        } else {
            ZStack {
                // Captions are an overlay on the picture, never a sibling of it.
                // A `Text` that has to wrap into more lines than the 16:9 box
                // is tall reports that taller height, the ZStack that holds it
                // grows to match, and the picture is then drawn into a box that
                // is no longer 16:9 — the video visibly overshoots its frame
                // whenever a cue is long. An overlay is measured against the
                // picture and cannot change its size, so a cue of any length
                // draws over the frame instead of resizing it.
                surfaceCanvas
                    .overlay(alignment: .bottom) { captionOverlay }
                    .overlay { levelOverlay }

                if model.isBuffering || model.isReloading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.textPrimary.color)
                        .allowsHitTesting(false)
                }

                if model.controlsVisible {
                    controls
                }

                skipPill
                unlockControl
            }
            // Black behind the whole stage: in fullscreen the canvas alone covers
            // the display, but the stage is what a 16:9 portrait frame letterboxes
            // against.
            .background {
                Color.black
                    .fullBleed(model.isFullscreen)
            }
        }
    }

    /// Everything that should reach the screen edges in fullscreen: the picture,
    /// its gestures, the scrim and the black behind them. One container, so the
    /// canvas — not just its individual children — is what ignores the safe
    /// area.
    private var surfaceCanvas: some View {
        ZStack {
            Color.black

            videoLayer
                // The notch only overlaps the picture in landscape; portrait has
                // nothing to avoid. `safeAreaPadding` reads the live insets, so
                // a rotation or a call-status bar cannot leave a stale value.
                .avoidNotch(model.isFullscreen && avoidsNotch)
                .contentShape(Rectangle())

            gestureLayer

            if model.controlsVisible {
                // The scrim is decoration only: letting it take hit tests would
                // swallow the tap that is supposed to hide the overlay.
                controlsScrim
                    .allowsHitTesting(false)
            }
        }
        .fullBleed(model.isFullscreen)
    }

    /// The picture itself. Whether fullscreen bleeds it through the safe area is
    /// decided by the canvas that owns it, alongside the gesture layer and the
    /// scrim.
    private var videoLayer: some View {
        PlayerLayerView(
            player: model.player,
            fillsScreen: fillsScreen,
            onLayerReady: { model.attachSurface($0) }
        )
    }

    /// The picture's own gestures: a tap toggles the chrome, a double tap skips
    /// one side ten seconds, and a downward swipe leaves fullscreen.
    ///
    /// Split into halves rather than measured: SwiftUI already knows which side
    /// was tapped, and two halves cannot disagree with the layout.
    private var gestureLayer: some View {
        // Measured, because the two edge swipes are decided by where the finger
        // went down: brightness on the left, volume on the right, and the middle
        // left to the fullscreen-exit swipe.
        GeometryReader { proxy in
            HStack(spacing: 0) {
                tapHalf(forward: false)
                tapHalf(forward: true)
            }
            .simultaneousGesture(exitSwipe(width: proxy.size.width))
            .simultaneousGesture(levelSwipe(size: proxy.size))
            .simultaneousGesture(notchPinch)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Video")
        .accessibilityHint("Toggles the controls. Double-tap a side to skip ten seconds. Drag the edges to set brightness and volume.")
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
    ///
    /// The middle third only: the edges belong to the brightness and volume
    /// swipes, and a downward drag there is how they go down.
    private func exitSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard model.isFullscreen, !model.isLocked else { return }
                let offset = value.translation
                guard offset.height > 60, abs(offset.height) > abs(offset.width) else { return }
                guard isMiddle(value.startLocation.x, width: width) else { return }
                model.setFullscreen(false)
            }
    }

    private func isMiddle(_ x: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return true }
        return x > width / 3 && x < width * 2 / 3
    }

    /// Vertical drags at the edges: brightness on the left, volume on the right.
    ///
    /// The level shown is the one being changed, so the gesture announces
    /// itself on the picture instead of silently moving a setting. A quarter of
    /// the picture's height per full range keeps a thumb-sized drag usable in
    /// portrait, where the 16:9 frame is only a few hundred points tall.
    private func levelSwipe(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !model.isLocked, size.width > 0 else { return }
                // A horizontal drag is not a level: that is the scrubber's.
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let side = size.width / 3
                let kind: LevelHUD.Kind
                if value.startLocation.x <= side {
                    kind = .brightness
                } else if value.startLocation.x >= size.width - side {
                    kind = .volume
                } else {
                    return
                }
                // Anchored at the level the gesture started on, so a second swipe
                // does not jump back to where the first one began.
                if levelDrag?.kind != kind {
                    levelDrag = LevelDrag(kind: kind, start: levelValue(kind))
                }
                guard let anchor = levelDrag else { return }
                let travel = max(size.height, 1) * 0.4
                setLevel(kind, anchor.start - Double(value.translation.height / travel))
                showLevel(kind)
            }
            .onEnded { _ in
                levelDrag = nil
                hideLevelAfterPause()
            }
    }

    private func levelValue(_ kind: LevelHUD.Kind) -> Double {
        switch kind {
        case .volume: model.volume
        case .brightness: model.brightness
        }
    }

    private func setLevel(_ kind: LevelHUD.Kind, _ value: Double) {
        switch kind {
        case .volume: model.setVolume(value, revealsControls: false)
        case .brightness: model.setBrightness(value)
        }
    }

    /// The readout appears while the finger is down and lingers briefly after,
    /// then takes itself away: the picture is the point, not the slider.
    private func showLevel(_ kind: LevelHUD.Kind) {
        let hud = LevelHUD(kind: kind, value: levelValue(kind))
        if levelHUD == nil {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { levelHUD = hud }
        } else {
            levelHUD = hud
        }
        levelHideTask?.cancel()
    }

    private func hideLevelAfterPause() {
        levelHideTask?.cancel()
        levelHideTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { levelHUD = nil }
        }
    }

    /// The zoom-to-fit affordance `AVPlayerViewController` ships: pinching in
    /// brings the picture inside the safe area, pinching out fills the display
    /// again. Fullscreen only — portrait has nothing beside the picture to avoid.
    ///
    /// Hysteresis around 1.0 so the small magnification a tap produces cannot
    /// flip the setting on its own.
    private var notchPinch: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                guard model.isFullscreen, !model.isLocked else { return }
                if value.magnification < 0.92 {
                    avoidsNotch = true
                } else if value.magnification > 1.08 {
                    avoidsNotch = false
                }
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

    /// The active cue, pinned to the bottom of the picture.
    ///
    /// Drawn as an overlay so it never takes part in the player's layout (see
    /// ``playerSurface()``), and capped at six lines: a malformed track with a
    /// paragraph-long cue must not paint over the whole frame, and six lines is
    /// past anything a real caption uses.
    @ViewBuilder
    private var captionOverlay: some View {
        if let cue = model.activeCue {
            Text(cue.text)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(theme.textPrimary.color)
                .multilineTextAlignment(.center)
                .lineLimit(6)
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

    /// The level readout: a slim rail on the edge being dragged, with the icon
    /// of what is changing. It appears only while a level moves and lingers for
    /// less than a second after, so the picture is never permanently covered.
    @ViewBuilder
    private var levelOverlay: some View {
        if let hud = levelHUD {
            VStack(spacing: Layout.spacing1) {
                Image(systemName: hud.kind == .volume ? model.volumeSymbol : "sun.max.fill")
                    .font(.caption)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule()
                        .fill(.white)
                        .frame(height: max(4, 96 * hud.value))
                }
                .frame(width: 5, height: 96)
                Text("\(Int((hud.value * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
            }
            .foregroundStyle(theme.textPrimary.color)
            .padding(.vertical, Layout.spacing2)
            .padding(.horizontal, 6)
            .background(
                .black.opacity(0.5),
                in: RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous)
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: hud.kind == .volume ? .trailing : .leading
            )
            .padding(Layout.spacing4)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(hud.kind == .volume ? "Volume" : "Brightness")
            .accessibilityValue("\(Int((hud.value * 100).rounded())) percent")
            .transition(.opacity)
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
        // The portrait 16:9 box is 240 pt tall on a 428 pt-wide phone, so the
        // volume row fits — until Dynamic Type grows the clock and the scrubber.
        // `ViewThatFits` drops that row rather than letting the chrome draw
        // outside the picture it belongs to.
        ViewThatFits(in: .vertical) {
            chrome(showsUtility: true)
            chrome(showsUtility: false)
        }
        // The surface is the full picture, but this stack stays inside the
        // device safe area, so the transport never lands under the notch or the
        // home indicator. Only the picture and its scrim bleed out.
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private func chrome(showsUtility: Bool) -> some View {
        VStack(spacing: Layout.spacing2) {
            topRow
            Spacer(minLength: 0)
            transportRow
            scrubberRow
            if showsUtility { utilityRow }
        }
    }

    private var topRow: some View {
        HStack(spacing: Layout.spacing1) {
            iconButton("xmark", label: "Close player") { dismiss() }
            if model.isPlayingLocal { downloadedBadge }
            Spacer(minLength: 0)
            if model.speed != 1 {
                Chip(text: model.speedLabel, prominent: true)
                    .lineLimit(1)
            }
            optionsButton
            iconButton(
                model.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: model.isFullscreen ? "Exit fullscreen" : "Enter fullscreen"
            ) {
                // An explicit pick owns the mode from here: a later turn of the
                // phone must not silently undo it.
                fullscreenFromRotation = false
                model.toggleFullscreen()
            }
        }
    }

    /// The badge that says these bytes are on the device, which is the promise
    /// the Downloads screen makes.
    ///
    /// Icon-only in the chrome: the word "Downloaded" belongs with the details
    /// chips below the picture, where there is room to spell it out.
    private var downloadedBadge: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(theme.textPrimary.color)
            .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
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

    /// Everything about the session rather than the transport, kept inside the
    /// picture in both orientations.
    ///
    /// Only the controls a viewer reaches for mid-scene stay here. Fill, notch,
    /// PiP, AirPlay and download live in the options sheet: they are decisions
    /// about the session, and their 44 pt targets were what made the portrait
    /// chrome drop this row entirely at large text sizes.
    private var utilityRow: some View {
        HStack(spacing: Layout.spacing2) {
            // The volume *level* lives on the right edge of the picture, where a
            // thumb swipes for it; the button stays for the one action a swipe
            // cannot express.
            iconButton(model.volumeSymbol, label: model.isMuted ? "Unmute" : "Mute") {
                model.toggleMute()
            }

            Spacer(minLength: 0)

            iconButton(
                model.isLocked ? "lock.fill" : "lock.open",
                label: model.isLocked ? "Unlock controls" : "Lock controls"
            ) {
                model.toggleLock()
            }
        }
    }

    /// A plain button, never a `Menu`: the menu rebuilt its action list on every
    /// playhead tick and flickered under the finger. The sheet is presented
    /// once and owns a stable hierarchy.
    private var optionsButton: some View {
        iconButton("ellipsis.circle.fill", label: "Playback options and source") {
            showsOptions = true
        }
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

    /// Runs the Download row's request once the sheet is gone, so its result can
    /// be shown as an alert rather than silently refused by UIKit.
    private func downloadAfterOptions() {
        guard pendingDownload else { return }
        pendingDownload = false
        Task { await queueDownload() }
    }

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
}

/// Fullscreen lets only the picture and its gestures leave the safe area; the
/// chrome stays inside it, which is what keeps every button on screen.
private struct FullBleed: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.ignoresSafeArea()
        } else {
            content
        }
    }
}

/// Pulls the picture back inside the safe area without giving up the
/// edge-to-edge frame.
///
/// Only the video layer is inset; the surface around it keeps bleeding, so the
/// strip the notch would have covered is black rather than showing wallpaper.
/// This is the "reduce, but do not letterbox the whole screen" behaviour a
/// viewer expects from a landscape player.
private struct NotchAvoiding: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.safeAreaPadding(.horizontal)
        } else {
            content
        }
    }
}

extension View {
    fileprivate func fullBleed(_ isActive: Bool) -> some View {
        modifier(FullBleed(isActive: isActive))
    }

    fileprivate func avoidNotch(_ isActive: Bool) -> some View {
        modifier(NotchAvoiding(isActive: isActive))
    }
}
