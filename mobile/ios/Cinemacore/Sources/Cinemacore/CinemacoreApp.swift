import SwiftUI
import CinemacoreCore

@main
struct CinemacoreApp: App {
    @State private var app = AppModel(
        library: FileLibraryStore(directory: Self.libraryDirectory)
    )
    @State private var showsSplash = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Screens capture the repository when they are constructed, so
                // the root is not built until the catalog source is resolved.
                if app.bootstrapped {
                    RootView(app: app)
                        .id(app.repositoryGeneration)
                } else {
                    Theme.app.background.color.ignoresSafeArea()
                }

                if showsSplash {
                    SplashView { hideSplash(duration: 0.45) }
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .environment(\.theme, .app)
            // The brand is dark-only: the source app's "light" palette is
            // byte-identical to its dark one, so a light mode would be invented.
            .preferredColorScheme(.dark)
            .task {
                await app.bootstrap()
                // A splash that outlives its work is just a delay.
                try? await Task.sleep(for: .milliseconds(1100))
                hideSplash(duration: 0.4)
            }
        }
    }

    /// Reduce Motion gets the same hand-over with no fade.
    private func hideSplash(duration: Double) {
        guard !reduceMotion else {
            showsSplash = false
            return
        }
        withAnimation(.easeOut(duration: duration)) { showsSplash = false }
    }

    /// Library state lives in Application Support so iOS backs it up but does
    /// not expose it to the Files app.
    nonisolated static var libraryDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Cinemacore", isDirectory: true)
    }

    /// Downloads sit beside the library rather than in Caches: a finished
    /// download is user data, and the OS may purge Caches at any time.
    nonisolated static var downloadsDirectory: URL {
        libraryDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }
}
