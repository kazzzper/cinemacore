import SwiftUI
import CinemacoreCore

/// Settings, including the data-source switch.
struct SettingsScreen: View {
    let app: AppModel

    @State private var gatewayDraft = ""
    @Environment(\.theme) private var theme

    private var sourceBinding: Binding<CatalogResolver.SourceMode> {
        Binding(
            get: { app.settings.sourceMode },
            set: { mode in Task { await app.setSourceMode(mode) } }
        )
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            List {
                Section {
                    Picker("Catalog source", selection: sourceBinding) {
                        Text("Built-in (direct)").tag(CatalogResolver.SourceMode.builtIn)
                        Text("StreamHype (web)").tag(CatalogResolver.SourceMode.streamHype)
                        Text("Gateway server").tag(CatalogResolver.SourceMode.gateway)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(app.isLive ? Color.green : theme.accent.color)
                                .frame(width: 8, height: 8)
                            Text(app.sourceNote)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }
                } header: {
                    Text("Data source")
                } footer: {
                    Text(sourceFooter)
                }

                if app.settings.sourceMode == .gateway {
                    Section {
                        TextField("http://192.168.1.20:8080", text: $gatewayDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        Button("Apply and reconnect") {
                            Task {
                                await app.setGatewayURL(
                                    gatewayDraft.isEmpty ? nil : gatewayDraft
                                )
                            }
                        }
                        .disabled(gatewayDraft == (app.settings.gatewayURL ?? ""))
                    } header: {
                        Text("Gateway")
                    } footer: {
                        Text("Use your machine's LAN address; 127.0.0.1 on the phone is the phone itself.")
                    }
                }

                Section("Library") {
                    NavigationLink(value: Route.history) {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(value: Route.manageCategories) {
                        Label("Manage Categories", systemImage: "square.grid.2x2")
                    }
                }

                Section("Playback") {
                    Toggle(
                        "Autoplay next episode",
                        isOn: Binding(
                            get: { app.settings.autoPlayNext },
                            set: { value in
                                Task { await app.updateSettings { $0.autoPlayNext = value } }
                            }
                        )
                    )
                    .tint(theme.brand.color)
                }

                Section("About") {
                    NavigationLink(value: Route.docs) {
                        Label("Docs", systemImage: "book")
                    }
                    NavigationLink(value: Route.lab) {
                        Label("Lab", systemImage: "wrench.and.screwdriver")
                    }
                    LabeledContent("Version", value: "0.1.0")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { gatewayDraft = app.settings.gatewayURL ?? "" }
    }

    private var sourceFooter: String {
        switch app.settings.sourceMode {
        case .gateway:
            "The gateway is your own Cinemacore server (go run ./cmd/cinemacore)."
        case .streamHype:
            "Catalog from TMDB; playback opens the StreamHype web player in-app. Downloads and offline play are not offered on this source. StreamHype's published TMDB key is used by default; set TMDBAPIKey in Info.plist or TMDB_API_KEY in the environment to use your own."
        case .builtIn:
            "Built-in talks to the catalog directly — no server required."
        }
    }
}
