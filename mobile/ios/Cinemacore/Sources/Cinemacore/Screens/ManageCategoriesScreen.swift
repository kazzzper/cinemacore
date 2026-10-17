import SwiftUI
import CinemacoreCore

/// Reorder and hide the rails shown on Home.
///
/// Mirrors the Android app's Manage Categories screen, but stores the result in
/// the shared settings document instead of a separate preference file.
struct ManageCategoriesScreen: View {
    let app: AppModel

    @State private var rails: [String] = []
    @State private var hidden: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            if isLoading {
                LoadingView(message: "Loading categories")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load categories", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if rails.isEmpty {
                ContentUnavailableView(
                    "No categories",
                    systemImage: "square.grid.2x2",
                    description: Text("This catalog doesn't expose any rails.")
                )
            } else {
                List {
                    ForEach(rails, id: \.self) { rail in
                        Button {
                            toggle(rail)
                        } label: {
                            HStack {
                                Image(systemName: hidden.contains(rail) ? "eye.slash" : "eye")
                                    .foregroundStyle(
                                        hidden.contains(rail) ? theme.textSecondary.color : theme.brand.color
                                    )
                                    .frame(width: 22)
                                Text(rail)
                                    .foregroundStyle(theme.textPrimary.color)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(hidden.contains(rail) ? [] : .isSelected)
                    }
                    .onMove(perform: move)
                }
                .environment(\.editMode, .constant(.active))
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Manage Categories")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let page = try await app.repository.home()
            let titles = page.sections.map(\.title)
            // A saved order wins, but rails the provider added since are appended
            // so nothing becomes unreachable.
            let saved = app.settings.categoryOrder.filter(titles.contains)
            let added = titles.filter { !saved.contains($0) }
            rails = saved + added
            hidden = app.settings.hiddenRails
        } catch {
            errorMessage = error.userMessage
        }
        isLoading = false
    }

    private func toggle(_ rail: String) {
        if hidden.contains(rail) {
            hidden.remove(rail)
        } else {
            hidden.insert(rail)
        }
        persist()
    }

    private func move(from source: IndexSet, to destination: Int) {
        rails.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        let order = rails
        let hiddenRails = hidden
        Task {
            await app.updateSettings {
                $0.categoryOrder = order
                $0.hiddenRails = hiddenRails
            }
        }
    }
}
