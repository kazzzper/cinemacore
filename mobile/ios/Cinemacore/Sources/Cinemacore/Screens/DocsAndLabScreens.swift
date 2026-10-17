import SwiftUI
import CinemacoreCore

/// Developer surface: inspect the data source and preview the gate screens.
///
/// The Android build has the same screen, where it hides the reverse-engineering
/// knobs. Here it exposes only what is useful for support and review.
struct LabScreen: View {
    let app: AppModel

    @State private var gatewayVersion: String?
    @State private var probedGateway = false
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            List {
                Section("Catalog") {
                    LabeledContent("Source") {
                        Text(app.sourceNote)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                    LabeledContent("Mode", value: app.isLive ? "Live gateway" : "Bundled catalog")
                    LabeledContent("Gateway", value: app.settings.gatewayURL ?? "default")
                    LabeledContent("Gateway version") {
                        Text(gatewayVersion ?? (probedGateway ? "unreachable" : "checking"))
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }

                Section {
                    ForEach(GatePreview.allCases) { gate in
                        Button {
                            app.previewGate = gate
                        } label: {
                            Label(gate.title, systemImage: gate.systemImage)
                        }
                    }
                } header: {
                    Text("Preview gates")
                } footer: {
                    Text(
                        "These screens normally appear only when the gateway demands "
                        + "them. Use this to check their layout."
                    )
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Lab")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            gatewayVersion = await app.gatewayVersion()
            probedGateway = true
        }
    }
}

/// One documented topic.
struct DocChapter: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let sections: [DocSection]

    struct DocSection: Identifiable {
        let id: String
        let heading: String
        let body: String
    }
}

/// In-app documentation: what the app is, how to point it at a gateway, and
/// what to do when something breaks.
struct DocsScreen: View {
    @Environment(\.theme) private var theme

    private let chapters: [DocChapter] = [
        DocChapter(
            id: "start",
            title: "Getting started",
            systemImage: "play.circle",
            sections: [
                .init(
                    id: "browse",
                    heading: "Browsing",
                    body: "Home shows rails from the active catalog. Tap any poster for "
                        + "details, episodes, and cast. Search matches titles and genres."
                ),
                .init(
                    id: "resume",
                    heading: "Resuming",
                    body: "Playback position is saved while you watch, so History can "
                        + "take you back to where you stopped."
                )
            ]
        ),
        DocChapter(
            id: "gateway",
            title: "Live data",
            systemImage: "antenna.radiowaves.left.and.right",
            sections: [
                .init(
                    id: "why",
                    heading: "Why you might see demo data",
                    body: "On launch the app probes the gateway. If it doesn't answer "
                        + "within a few seconds, the bundled catalog is used so you can "
                        + "still browse. The banner on Home tells you which is active."
                ),
                .init(
                    id: "point",
                    heading: "Pointing at your own gateway",
                    body: "Settings lists the current source and lets you enter a gateway "
                        + "URL. Applying it reconnects and rebuilds every screen."
                )
            ]
        ),
        DocChapter(
            id: "playback",
            title: "Playback",
            systemImage: "film",
            sections: [
                .init(
                    id: "quality",
                    heading: "Quality",
                    body: "The provider returns one stream with several labels, the first "
                        + "of which is Auto. Picking a quality is a hint to the player, "
                        + "not a different file, so switching never buffers from scratch."
                ),
                .init(
                    id: "subtitles",
                    heading: "Subtitles",
                    body: "Tracks arrive as WebVTT or SRT. SRT is converted on device "
                        + "before playback because the player only renders WebVTT."
                )
            ]
        ),
        DocChapter(
            id: "privacy",
            title: "Privacy",
            systemImage: "hand.raised",
            sections: [
                .init(
                    id: "stored",
                    heading: "What is stored",
                    body: "Your watchlist, resume positions, and preferences stay on this "
                        + "device. Only catalog requests leave it."
                ),
                .init(
                    id: "ats",
                    heading: "Transport security",
                    body: "App Transport Security is left at its defaults. The only "
                        + "exception is local networking, so a gateway on your own "
                        + "machine can be reached."
                )
            ]
        )
    ]

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.spacing5) {
                    ForEach(chapters) { chapter in
                        chapterView(chapter)
                    }
                }
                .padding(Layout.spacing4)
            }
        }
        .navigationTitle("Docs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chapterView(_ chapter: DocChapter) -> some View {
        VStack(alignment: .leading, spacing: Layout.spacing3) {
            Label(chapter.title, systemImage: chapter.systemImage)
                .font(Typography.sectionTitle)
                .foregroundStyle(theme.textPrimary.color)

            ForEach(chapter.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.heading)
                        .font(Typography.rowTitle)
                        .foregroundStyle(theme.textPrimary.color)
                    Text(section.body)
                        .font(Typography.body)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Layout.spacing3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    theme.surface.color,
                    in: RoundedRectangle(cornerRadius: Layout.radiusMedium, style: .continuous)
                )
            }
        }
    }
}
