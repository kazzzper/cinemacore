import SwiftUI
import CinemacoreCore

/// The tab shell. Five tabs, matching the Android build's navigation bar.
struct RootView: View {
    @Bindable var app: AppModel

    @State private var selection: TabID = .home
    @State private var homePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var watchlistPath = NavigationPath()
    @State private var downloadsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    enum TabID: Hashable {
        case home, search, watchlist, downloads, settings
    }

    var body: some View {
        tabsView
            .tint(Theme.app.brand.color)
            .overlay { fullScreenGate }
            // The dismissible gates are real presentations, so their detents and
            // presentation background take effect; an overlay ignores both.
            .sheet(item: sheetGate) { gate in
                sheetContent(gate)
            }
    }

    @ViewBuilder
    private var tabsView: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house.fill", value: TabID.home) { homeStack }
                Tab("Search", systemImage: "magnifyingglass", value: TabID.search) { searchStack }
                Tab("Watchlist", systemImage: "bookmark.fill", value: TabID.watchlist) { watchlistStack }
                Tab("Downloads", systemImage: "arrow.down.circle.fill", value: TabID.downloads) { downloadsStack }
                Tab("Settings", systemImage: "gearshape.fill", value: TabID.settings) { settingsStack }
            }
        } else {
            TabView(selection: $selection) {
                homeStack.tabItem { Label("Home", systemImage: "house.fill") }.tag(TabID.home)
                searchStack.tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(TabID.search)
                watchlistStack.tabItem { Label("Watchlist", systemImage: "bookmark.fill") }.tag(TabID.watchlist)
                downloadsStack.tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }.tag(TabID.downloads)
                settingsStack.tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(TabID.settings)
            }
        }
    }

    private var homeStack: some View {
        NavigationStack(path: $homePath) { HomeScreen(app: app).appRoutes(app) }
    }
    private var searchStack: some View {
        NavigationStack(path: $searchPath) { SearchScreen(app: app).appRoutes(app) }
    }
    private var watchlistStack: some View {
        NavigationStack(path: $watchlistPath) { WatchlistScreen(app: app).appRoutes(app) }
    }
    private var downloadsStack: some View {
        NavigationStack(path: $downloadsPath) { DownloadsScreen(app: app).appRoutes(app) }
    }
    private var settingsStack: some View {
        NavigationStack(path: $settingsPath) { SettingsScreen(app: app).appRoutes(app) }
    }

    /// `LockoutScreen` and `ForceUpdateScreen` are takeovers, so they stay in
    /// the overlay; only the dismissible gates are presented.
    @ViewBuilder
    private var fullScreenGate: some View {
        if let gate = app.previewGate, !gate.isModalSheet {
            switch gate {
            case .lockout:
                LockoutScreen { app.previewGate = nil }
            case .forceUpdate:
                ForceUpdateScreen { app.previewGate = nil }
            case .appUpdate, .joinCommunity:
                EmptyView()
            }
        }
    }

    private var sheetGate: Binding<GatePreview?> {
        Binding(
            get: { app.previewGate.flatMap { $0.isModalSheet ? $0 : nil } },
            set: { app.previewGate = $0 }
        )
    }

    @ViewBuilder
    private func sheetContent(_ gate: GatePreview) -> some View {
        switch gate {
        case .appUpdate:
            AppUpdateDialog { app.previewGate = nil }
        case .joinCommunity:
            JoinCommunitySheet { app.previewGate = nil }
        case .lockout, .forceUpdate:
            EmptyView()
        }
    }
}
