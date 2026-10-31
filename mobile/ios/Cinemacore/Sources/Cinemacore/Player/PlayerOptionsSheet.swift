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
///
/// # Why tabs
///
/// The sheet used to be one flat list of nine sections. For a series that meant
/// every episode of the selected season — and with a long season, every section
/// above it — so reaching Subtitles meant scrolling past thirty rows. Four tabs
/// put the thing a viewer opened the sheet for at most one tap away, and the
/// episode picker became a grid of numbers rather than a list of titles.
struct PlayerOptionsSheet: View {
    let model: PlayerModel
    @Binding var fillsScreen: Bool
    @Binding var avoidsNotch: Bool
    let download: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var tab: Tab

    /// The four things a viewer opens this sheet to change.
    ///
    /// A movie has no episodes, so the tab is not offered at all rather than
    /// opening on an empty grid.
    enum Tab: String, CaseIterable, Hashable {
        case episodes = "Episodes"
        case subtitles = "Subtitles"
        case audio = "Audio & Quality"
        case display = "Display"

        var symbol: String {
            switch self {
            case .episodes: "rectangle.stack"
            case .subtitles: "captions.bubble"
            case .audio: "waveform"
            case .display: "rectangle.inset.filled"
            }
        }
    }

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
        // A series opens where a viewer watching a series actually wants to be.
        _tab = State(initialValue: model.isSeries ? .episodes : .subtitles)
    }

    private var tabs: [Tab] {
        Tab.allCases.filter { $0 != .episodes || model.isSeries }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                Divider().overlay(theme.separator.color)
                content
            }
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

    /// A horizontally scrollable segmented row, so four tabs still fit at the
    /// largest Dynamic Type sizes without truncating to initials.
    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Layout.spacing2) {
                ForEach(tabs, id: \.self) { item in
                    Button {
                        tab = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(Typography.metadata.weight(.semibold))
                            .foregroundStyle(
                                tab == item ? theme.background.color : theme.textPrimary.color
                            )
                            .padding(.horizontal, Layout.spacing3)
                            .frame(minHeight: 36)
                            .background(
                                tab == item ? theme.textPrimary.color : theme.surfaceElevated.color,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, Layout.spacing4)
            .padding(.vertical, Layout.spacing3)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .episodes:
            episodeTab
        case .subtitles:
            subtitleTab
        case .audio:
            audioTab
        case .display:
            displayTab
        }
    }

    // MARK: - Episodes

    /// A season strip above a numbered grid.
    ///
    /// The grid is the change that matters: a twenty-four episode season was
    /// twenty-four full-width rows with a title each, which is a whole screen of
    /// scrolling for one tap. Numbers in a grid are faster to scan and to hit,
    /// and the title of the episode that is playing is still readable below.
    private var episodeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing4) {
                if model.seasonNumbers.count > 1 {
                    seasonPicker
                }
                if model.episodes.isEmpty {
                    message("Episodes are not available yet.")
                } else {
                    episodeGrid
                }
                if let episode = model.playingEpisode {
                    Text("Now playing · S\(episode.season) E\(episode.number) · \(episode.displayTitle)")
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                        .padding(.horizontal, Layout.spacing4)
                }
            }
            .padding(.vertical, Layout.spacing4)
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
                            .frame(minHeight: 36)
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
            .padding(.horizontal, Layout.spacing4)
        }
        .scrollIndicators(.hidden)
    }

    private var episodeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64), spacing: Layout.spacing2)],
            spacing: Layout.spacing2
        ) {
            ForEach(model.episodes) { episode in
                episodeCell(episode)
            }
        }
        .padding(.horizontal, Layout.spacing4)
    }

    private func episodeCell(_ episode: Episode) -> some View {
        let playing = episode.id == model.playingEpisode?.id
        return Button {
            Task { await model.selectEpisode(episode) }
            dismiss()
        } label: {
            VStack(spacing: 2) {
                Text("\(episode.number)")
                    .font(Typography.rowTitle.monospacedDigit())
                if let duration = episode.durationText {
                    Text(duration)
                        .font(Typography.badge)
                        .foregroundStyle(
                            playing
                                ? theme.background.color.opacity(0.8)
                                : theme.textSecondary.color
                        )
                }
            }
            .foregroundStyle(playing ? theme.background.color : theme.textPrimary.color)
            .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
            .background(
                playing ? theme.textPrimary.color : theme.surfaceElevated.color,
                in: RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.radiusSmall, style: .continuous)
                    .strokeBorder(playing ? .clear : theme.separator.color, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Season \(episode.season) episode \(episode.number), \(episode.displayTitle)")
        .accessibilityAddTraits(playing ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Subtitles

    /// Off, then one section per source.
    ///
    /// The source heading is what makes two "English" rows tellable apart: the
    /// provider's own caption and a community file in the same language are
    /// different subtitles, and picking the wrong one shows dialogue that does
    /// not match the picture.
    private var subtitleTab: some View {
        List {
            SwiftUI.Section {
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

            communityStatusSection
        }
        .scrollContentBackground(.hidden)
    }

    /// Says what the community lookup is doing, and offers the retry.
    ///
    /// Without this an empty Community section is indistinguishable from a
    /// source that does not exist — which is exactly how "the community
    /// subtitles are missing" reads to a viewer.
    @ViewBuilder
    private var communityStatusSection: some View {
        switch model.subtitleAvailability {
        case .idle:
            EmptyView()

        case .loading:
            SwiftUI.Section("Community") {
                HStack(spacing: Layout.spacing3) {
                    ProgressView().controlSize(.small)
                    Text("Looking for community subtitles…")
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                }
                .frame(minHeight: Layout.minimumTarget)
                .listRowBackground(theme.surface.color)
            }

        case .available:
            if model.subtitleTracks(from: .community).isEmpty {
                SwiftUI.Section("Community") {
                    communityRetryRow("Community subtitles were found but the list is empty.")
                }
            }

        case .unavailable:
            SwiftUI.Section("Community") {
                communityRetryRow(
                    "No community subtitles were found for this episode. They need a connection to load."
                )
            }
        }
    }

    private func communityRetryRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacing2) {
            Text(text)
                .font(Typography.metadata)
                .foregroundStyle(theme.textSecondary.color)
            Button {
                Task { await model.retryCommunitySubtitles() }
            } label: {
                Label("Search again", systemImage: "arrow.clockwise")
                    .font(Typography.button)
            }
            .buttonStyle(.borderless)
            .frame(minHeight: Layout.minimumTarget)
            .accessibilityHint("Looks for community subtitles again")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(theme.surface.color)
    }

    /// The release label and the format, so two files in one language read
    /// differently and a viewer can match one to their copy.
    private func subtitleDetail(_ track: SubtitleTrack) -> String? {
        let format = track.needsConversion ? "SRT" : "VTT"
        guard let source = track.source, !source.isEmpty else { return format }
        return "\(source) · \(format)"
    }

    // MARK: - Audio & quality

    private var audioTab: some View {
        List {
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

            if model.audioTracks.count > 1 {
                SwiftUI.Section("Audio Track") {
                    ForEach(model.audioTracks) { track in
                        choiceRow(track.label, selected: track == model.selectedAudioTrack) {
                            model.selectAudioTrack(track)
                            dismiss()
                        }
                    }
                }
            }

            if !model.renditions.isEmpty {
                SwiftUI.Section("Quality") {
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
                }
            }

            SwiftUI.Section("Speed") {
                ForEach(PlayInfo.speedOptions, id: \.self) { value in
                    choiceRow(PlayerModel.speedText(value), selected: value == model.speed) {
                        model.setSpeed(value)
                        dismiss()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Display

    private var displayTab: some View {
        List {
            SwiftUI.Section("Display") {
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
            }

            SwiftUI.Section("Playback") {
                Toggle(isOn: autoPlayNextBinding) {
                    settingLabel(
                        "Autoplay next episode",
                        detail: "Starts the next episode when this one ends."
                    )
                }
                .tint(theme.brand.color)
                .frame(minHeight: Layout.minimumTarget)
                .listRowBackground(theme.surface.color)
                .accessibilityLabel("Autoplay next episode")
            }

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
        .scrollContentBackground(.hidden)
    }

    /// The library already owns this preference, so the sheet writes through to
    /// it rather than keeping a second copy that dies with the screen.
    private var autoPlayNextBinding: Binding<Bool> {
        Binding(
            get: { model.autoPlayNext },
            set: { model.setAutoPlayNext($0) }
        )
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

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Typography.metadata)
            .foregroundStyle(theme.textSecondary.color)
            .padding(.horizontal, Layout.spacing4)
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
                            .lineLimit(2)
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
