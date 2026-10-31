import SwiftUI
import CinemacoreCore

/// Free-text search with type-ahead suggestions.
struct SearchScreen: View {
    let app: AppModel

    @State private var model: SearchViewModel
    @State private var query = ""
    /// The source generation `model` was built against, so a switch rebuilds it.
    @State private var builtGeneration: Int
    @Environment(\.theme) private var theme

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: SearchViewModel(repository: app.repository))
        _builtGeneration = State(initialValue: app.repositoryGeneration)
    }

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            if case .idle = model.state {
                ContentUnavailableView(
                    "Search Cinemacore",
                    systemImage: "magnifyingglass",
                    description: Text("Find movies and series by title, genre, or year.")
                )
            } else {
                StateView(
                    state: model.state,
                    loading: .spinner,
                    emptyTitle: "No matches",
                    emptyMessage: "Try a different title, genre, or year.",
                    emptyIcon: "magnifyingglass",
                    retry: { await model.submit(query) }
                ) { subjects in
                    ScrollView {
                        suggestRow
                        PosterGrid(subjects: subjects)
                            .padding(.top, Layout.spacing3)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Movies, series, genres")
        // The field's own clear control empties the text; resetting the model
        // here keeps the results and suggestions from outliving the query.
        .onChange(of: query) { _, value in
            if value.isEmpty {
                model.clear()
            } else {
                model.queryChanged(value)
            }
        }
        .onSubmit { Task { await model.submit(query) } }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        // A source switch changes which catalogue a query runs against. The
        // current results belong to the old one, so they are dropped and the
        // query is re-run rather than left pointing at a source no longer in use.
        .onChange(of: app.repositoryGeneration) { _, generation in
            guard generation != builtGeneration else { return }
            builtGeneration = generation
            model = SearchViewModel(repository: app.repository)
            guard !query.isEmpty else { return }
            Task { await model.submit(query) }
        }
    }

    @ViewBuilder
    private var suggestRow: some View {
        if !model.suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Layout.spacing2) {
                    ForEach(model.suggestions, id: \.self) { suggestion in
                        Button {
                            query = suggestion
                            Task { await model.submit(suggestion) }
                        } label: {
                            Chip(text: suggestion)
                                .frame(minHeight: Layout.minimumTarget)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Layout.spacing4)
            }
        }
    }
}
