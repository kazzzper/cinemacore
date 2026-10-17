import SwiftUI
import CinemacoreCore

/// Settings, including the data-source switch.
struct SettingsScreen: View {
    let app: AppModel

    @State private var gatewayDraft = ""
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            List {
                Section("Data source") {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(app.isLive ? Color.green : theme.accent.color)
                                .frame(width: 8, height: 8)
                            Text(app.sourceNote)
                                .foregroundStyle(theme.textSecondary.color)
                        }
                    }

                    TextField("Gateway URL", text: $gatewayDraft)
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
}
