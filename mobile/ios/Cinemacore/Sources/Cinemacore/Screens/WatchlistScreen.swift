import SwiftUI
import CinemacoreCore

/// Saved titles.
struct WatchlistScreen: View {
    let app: AppModel

    @State private var model: WatchlistViewModel
    @State private var confirmsClear = false
    @Environment(\.theme) private var theme

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: WatchlistViewModel(library: app.library))
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            StateView(
                state: model.state,
                emptyTitle: "Your watchlist is empty",
                emptyMessage: "Bookmark a title and it will show up here.",
                emptyIcon: "bookmark",
                retry: { await model.load() }
            ) { entries in
                ScrollView {
                    PosterGrid(
                        subjects: entries.map(\.subject),
                        onRemove: { subject in
                            Task {
                                await model.remove(subjectID: subject.id)
                                await app.refreshWatchlistIDs()
                            }
                        }
                    )
                }
            }
        }
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", role: .destructive) { confirmsClear = true }
                    .disabled(model.state.value?.isEmpty ?? true)
            }
        }
        .confirmationDialog(
            "Clear watchlist?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear Watchlist", role: .destructive) {
                Task {
                    await model.clear()
                    await app.refreshWatchlistIDs()
                }
            }
        } message: {
            Text("Every saved title is removed. This cannot be undone.")
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }
}
