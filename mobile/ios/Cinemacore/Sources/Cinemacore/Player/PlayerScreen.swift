import AVFoundation
import CinemacoreCore
import Foundation
import SwiftUI
import UIKit

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
                    details
                    Spacer(minLength: 0)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.controlsVisible)
        // The overlay owns every exit: an empty navigation bar above a video is
        // chrome for nothing.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { sheetContent($0) }
        .task { await model.start() }
        .onDisappear { model.stop() }
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
                    if model.languages.count > 1 { Chip(text: model.languageLabel) }
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

    @ViewBuilder
    private var playerBox: some View {
        if model.isFullscreen {
            playerSurface(videoIgnoresSafeArea: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            playerSurface(videoIgnoresSafeArea: false)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
    }

    private func playerSurface(videoIgnoresSafeArea: Bool) -> some View {
        ZStack {
            videoLayer(ignoringSafeArea: videoIgnoresSafeArea)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleControls() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Show or hide playback controls")

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
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func videoLayer(ignoringSafeArea: Bool) -> some View {
        if ignoringSafeArea {
            PlayerLayerView(player: model.player).ignoresSafeArea()
        } else {
            PlayerLayerView(player: model.player)
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

    private var controls: some View {
        VStack(spacing: Layout.spacing3) {
            HStack(spacing: Layout.spacing2) {
                iconButton("xmark", label: "Close player") { dismiss() }
                Spacer(minLength: 0)
                iconButton(
                    model.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: model.isFullscreen ? "Exit fullscreen" : "Enter fullscreen"
                ) {
                    model.toggleFullscreen()
                }
                settingsMenu
            }

            Spacer(minLength: 0)

            HStack(spacing: Layout.spacing5) {
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
                if model.hasNextEpisode {
                    iconButton("forward.end.fill", label: "Next episode", size: 22) {
                        Task { await model.playNextEpisode() }
                    }
                }
            }

            scrubber
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing3)
        .transition(.opacity)
    }

    private var scrubber: some View {
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
                    }
                }
            )
            .tint(theme.brand.color)
            .accessibilityLabel("Playback position")

            Text(PlayerModel.timeText(model.duration))
                .font(Typography.metadata.monospacedDigit())
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    private var settingsMenu: some View {
        Menu {
            if !model.languages.isEmpty {
                Button("Audio · \(model.languageLabel)") { sheet = .language }
            }
            if model.isSeries {
                Button("Season · \(model.selectedSeason)") { sheet = .season }
            }
            Button("Subtitles · \(model.subtitleLabel)") { sheet = .subtitle }
            Button("Quality · \(model.qualityLabel)") { sheet = .quality }
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

/// The six selection panels reachable from the controls.
private enum PlayerSheet: String, Identifiable {
    case language, season, subtitle, quality, speed, episodes

    var id: String { rawValue }
}

/// Draws the player's video without `AVKit`'s controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer?.player = player
        view.playerLayer?.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        view.playerLayer?.player = player
    }
}

/// A view whose backing layer *is* the player layer, so the video follows the
/// SwiftUI layout without any frame bookkeeping.
private final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}
