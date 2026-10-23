import CinemacoreCore
import SwiftUI

/// The stable replacement for the player's old settings `Menu`.
///
/// A menu rebuilt its action list whenever the player redrew the timeline —
/// four times a second — which made it flicker and tear down under the finger.
/// This sheet is presented once and owns its hierarchy. Its body reads only
/// selection state, never `model.position`, so the playhead cannot invalidate
/// it while it is open.
///
/// It is also where the controls that are not part of transport live now:
/// display fit, output routing and the download action. Keeping them out of the
/// chrome leaves the on-picture rows readable at large text sizes.
struct PlayerOptionsSheet: View {
    let model: PlayerModel
    @Binding var fillsScreen: Bool
    @Binding var avoidsNotch: Bool
    let download: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    init(
        model: PlayerModel,
        fillsScreen: Binding<Bool>,
        avoidsNotch: Binding<Bool>,
        download: @escaping () -> Void
    ) {
        self.model = model
        _fillsScreen = fillsScreen
        _avoidsNotch = avoidsNotch
        self.download = download
    }

    var body: some View {
        NavigationStack {
            List {
                displaySection
                outputSection
                downloadSection
                languageSection
                qualitySection
                audioSection
                subtitleSection
                speedSection
                episodeSection
            }
            .scrollContentBackground(.hidden)
            .background(theme.background.color)
            .navigationTitle("Playback Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }

    // MARK: - Sections

    private var displaySection: some View {
        SwiftUI.Section {
            Toggle(isOn: $fillsScreen) {
                settingLabel(
                    "Fill screen",
                    detail: fillsScreen
                        ? "The picture is cropped to the display edges."
                        : "The whole frame is letterboxed inside the display."
                )
            }
            .tint(theme.brand.color)
            .frame(minHeight: Layout.minimumTarget)
            .listRowBackground(theme.surface.color)
            .accessibilityLabel("Fill screen")
            .accessibilityHint("Crops the picture to the display edges instead of letterboxing it.")

            Toggle(isOn: $avoidsNotch) {
                settingLabel(
                    "Avoid notch",
                    detail: "Keep the picture clear of the sensor housing in landscape."
                )
            }
            .tint(theme.brand.color)
            .frame(minHeight: Layout.minimumTarget)
            .listRowBackground(theme.surface.color)
            .accessibilityLabel("Avoid notch")
            .accessibilityHint("Keeps the picture clear of the sensor housing in landscape.")
        } header: {
            Text("Display")
        }
    }

    /// PiP and AirPlay are session outputs rather than transport, so they are
    /// one row each instead of two more 44 pt targets over the picture.
    @ViewBuilder
    private var outputSection: some View {
        SwiftUI.Section("Output") {
            if PictureInPicture.isSupported {
                Button {
                    model.togglePictureInPicture()
                    dismiss()
                } label: {
                    actionRow(
                        model.isPiPActive ? "Leave Picture in Picture" : "Picture in Picture",
                        detail: model.canStartPictureInPicture
                            ? "Keep the video visible outside the app."
                            : "Available once the video is ready.",
                        symbol: model.isPiPActive ? "pip.exit" : "pip.enter"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.canStartPictureInPicture)
                .opacity(model.canStartPictureInPicture ? 1 : 0.45)
                .listRowBackground(theme.surface.color)
                .accessibilityLabel(
                    model.isPiPActive ? "Leave Picture in Picture" : "Picture in Picture"
                )
            }

            HStack(spacing: Layout.spacing3) {
                Label("AirPlay", systemImage: "airplayvideo")
                    .font(Typography.body)
                    .foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
                AirPlayRoutePicker(tint: theme.textPrimary.color)
                    .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
                    .accessibilityLabel("AirPlay route picker")
            }
            .frame(minHeight: Layout.minimumTarget)
            .listRowBackground(theme.surface.color)
        }
    }

    /// The current stream is the only thing the player can hand to the download
    /// queue without a second resolve, which could return a URL the viewer
    /// never chose.
    private var downloadSection: some View {
        SwiftUI.Section("Download") {
            Button {
                download()
                dismiss()
            } label: {
                actionRow(
                    model.isSeries ? "Download this episode" : "Download this movie",
                    detail: "Queues the quality you are watching for offline playback.",
                    symbol: "arrow.down.circle"
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(theme.surface.color)
            .accessibilityLabel(model.isSeries ? "Download this episode" : "Download this movie")
            .accessibilityHint("Adds the current stream to Downloads")
        }
    }

    /// Real language versions, not mirror hosts or container audio tracks.
    ///
    /// A dub is a separate upstream subject with its own `subjectId`; that id
    /// is what makes this picker change the bytes instead of just a checkmark.
    @ViewBuilder
    private var languageSection: some View {
        if model.dubOptions.count > 1 {
            SwiftUI.Section {
                ForEach(model.dubOptions) { dub in
                    choiceRow(
                        dub.displayName,
                        detail: dub.languageCode?.uppercased(),
                        selected: dub == model.selectedDub
                    ) {
                        Task { await model.selectDub(dub) }
                        dismiss()
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Each language is a separate provider source. Switching reloads from the same position.")
            }
        }
    }

    @ViewBuilder
    private var qualitySection: some View {
        if !model.renditions.isEmpty {
            SwiftUI.Section {
                ForEach(model.renditions) { rendition in
                    choiceRow(
                        rendition.quality,
                        detail: rendition.size,
                        selected: rendition == model.selectedRendition
                    ) {
                        model.selectQuality(rendition)
                        dismiss()
                    }
                }
            } header: {
                Text("Quality")
            }
        }
    }

    /// Only when the container actually carries a choice: an empty picker is
    /// worse than no section at all.
    @ViewBuilder
    private var audioSection: some View {
        if model.audioTracks.count > 1 {
            SwiftUI.Section("Audio Track") {
                ForEach(model.audioTracks) { track in
                    choiceRow(
                        track.label,
                        selected: track == model.selectedAudioTrack
                    ) {
                        model.selectAudioTrack(track)
                        dismiss()
                    }
                }
            }
        }
    }

    /// One section per source, so the viewer picks *where* a subtitle comes from
    /// before which one it is.
    ///
    /// A title can carry the provider's own track and several community files
    /// for the same language; listing them flat made two "English" rows that a
    /// viewer could not tell apart. The source heading is what makes the second
    /// choice meaningful.
    @ViewBuilder
    private var subtitleSection: some View {
        SwiftUI.Section("Subtitles") {
            choiceRow("Off", selected: model.selectedSubtitle == nil) {
                model.selectSubtitle(nil)
                dismiss()
            }
        }
        ForEach(model.subtitleSources, id: \.self) { source in
            SwiftUI.Section {
                ForEach(model.subtitleTracks(from: source)) { track in
                    choiceRow(
                        track.language,
                        detail: subtitleDetail(track),
                        selected: track == model.selectedSubtitle
                    ) {
                        model.selectSubtitle(track)
                        dismiss()
                    }
                }
            } header: {
                Text(source.label)
            } footer: {
                if source == .community {
                    Text("Community subtitles come from OpenSubtitles and are timed to a specific release. If the dialogue drifts, pick another one.")
                }
            }
        }
    }

    /// The release label and the format, so two files in one language read
    /// differently and a viewer can match one to their copy.
    private func subtitleDetail(_ track: SubtitleTrack) -> String? {
        let format = track.needsConversion ? "SRT" : "VTT"
        guard let source = track.source, !source.isEmpty else { return format }
        return "\(source) · \(format)"
    }

    private var speedSection: some View {
        SwiftUI.Section("Speed") {
            ForEach(PlayInfo.speedOptions, id: \.self) { value in
                choiceRow(PlayerModel.speedText(value), selected: value == model.speed) {
                    model.setSpeed(value)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var episodeSection: some View {
        if model.isSeries {
            SwiftUI.Section {
                // A season is a filter for the rows below rather than a choice
                // that ends the session, so it does not dismiss the sheet.
                if model.seasonNumbers.count > 1 {
                    seasonPicker
                }
                if model.episodes.isEmpty {
                    Text("Episodes are not available yet.")
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                        .listRowBackground(theme.surface.color)
                } else {
                    ForEach(model.episodes) { episode in
                        choiceRow(
                            episode.displayTitle,
                            detail: episode.durationText,
                            selected: episode.id == model.playingEpisode?.id
                        ) {
                            Task { await model.selectEpisode(episode) }
                            dismiss()
                        }
                    }
                }
            } header: {
                Text("Episodes")
            }
        }
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.spacing2) {
                ForEach(model.seasonNumbers, id: \.self) { number in
                    Button {
                        model.selectSeason(number)
                    } label: {
                        Text("Season \(number)")
                            .font(Typography.metadata.weight(.semibold))
                            .foregroundStyle(
                                number == model.selectedSeason
                                    ? theme.background.color
                                    : theme.textPrimary.color
                            )
                            .padding(.horizontal, Layout.spacing3)
                            .frame(minHeight: Layout.minimumTarget)
                            .background(
                                number == model.selectedSeason
                                    ? theme.textPrimary.color
                                    : theme.surfaceElevated.color,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        number == model.selectedSeason ? [.isButton, .isSelected] : .isButton
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .listRowBackground(theme.surface.color)
    }

    // MARK: - Rows

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typography.body)
                .foregroundStyle(theme.textPrimary.color)
            Text(detail)
                .font(Typography.metadata)
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    /// An action that lives in the sheet rather than on the picture. The row is
    /// one 44 pt target, like ``choiceRow``.
    private func actionRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: Layout.spacing3) {
            Image(systemName: symbol)
                .font(Typography.body)
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
            settingLabel(title, detail: detail)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .frame(minHeight: Layout.minimumTarget)
    }

    /// One selectable choice. A whole-row tap target and the selected trait
    /// match `SelectionCell`, so the two pickers behave the same way.
    private func choiceRow(
        _ title: String,
        detail: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Layout.spacing3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body)
                        .foregroundStyle(selected ? theme.accent.color : theme.textPrimary.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(Typography.metadata)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.accent.color)
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: Layout.minimumTarget)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.surface.color)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
