import SwiftUI
import CinemacoreCore

/// Renders the six states every screen must handle.
///
/// Centralised so no screen can quietly ship with only a success path, which is
/// how a loading spinner ends up being the permanent error UI.
struct StateView<Value: Sendable, Content: View>: View {
    let state: LoadState<Value>
    var loading: LoadingStyle = .spinner
    var emptyTitle: String = "Nothing here yet"
    var emptyMessage: String?
    var emptyIcon: String = "popcorn"
    var retry: (() async -> Void)?
    /// A failure the viewer cannot retry their way out of still needs an exit.
    /// Without this the only control on the screen is "Try Again", which on a
    /// permanent failure loops forever.
    var returnTitle: String = "Return"
    var returnAction: (() -> Void)?
    @ViewBuilder var content: (Value) -> Content

    enum LoadingStyle {
        case spinner
        case homeSkeleton
    }

    var body: some View {
        switch state {
        case .idle, .loading:
            switch loading {
            case .spinner: LoadingView()
            case .homeSkeleton: HomeSkeleton()
            }

        case .empty:
            terminal {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    if let emptyMessage { Text(emptyMessage) }
                } actions: {
                    // "The provider sent nothing" is not something a viewer can
                    // retry into working, so an empty screen needs the same exit a
                    // permanent failure does.
                    if let returnAction {
                        Button(returnTitle, action: returnAction)
                            .glassButton(prominent: true)
                    }
                }
            }

        case .failed(let error):
            terminal {
                ContentUnavailableView {
                    Label("Something went wrong", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    if error.isRetryable, let retry {
                        Button("Try Again") { Task { await retry() } }
                            .glassButton(prominent: true)
                    }
                    if let returnAction {
                        Button(returnTitle, action: returnAction)
                            .glassButton(prominent: !error.isRetryable || retry == nil)
                    }
                }
            }

        case .locked(let error):
            terminal {
                ContentUnavailableView {
                    Label("Not available", systemImage: "lock")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    if let returnAction {
                        Button(returnTitle, action: returnAction)
                            .glassButton(prominent: true)
                    }
                }
            }

        case .loaded(let value):
            content(value)

        case .partial(let value, let notice):
            VStack(spacing: 0) {
                NoticeBanner(text: notice)
                content(value)
            }
        }
    }

    /// The container every terminal state shares: the state owns the screen, and
    /// the exit owns the top-leading corner.
    ///
    /// `ContentUnavailableView` is centred at its intrinsic size, so with no
    /// frame of its own it is laid out inside whatever the host happens to
    /// propose — the player's 16:9 surface, a landscape canvas, or a navigation
    /// container mid-push — and that inheritance is what makes a failed title
    /// look enlarged rather than full-screen. Pinning the frame and the
    /// alignment keeps it at screen scale whatever it is handed.
    ///
    /// The pinned control is the other half of the fix: the actions above sit
    /// under the description, so they fall below the fold on a short screen or
    /// at a large text size — and the player hides the navigation bar outright,
    /// which leaves a permanent failure with no way off the screen at all.
    private func terminal<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        ZStack(alignment: .topLeading) {
            body()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let returnAction {
                // Secondary on purpose: the in-content action keeps the
                // emphasis, and a second prominent button doing the same thing
                // would compete with it. This one stands where the navigation
                // bar's own back button stood.
                Button(action: returnAction) {
                    Label("Back", systemImage: "chevron.left")
                        .font(Typography.button)
                        .frame(minHeight: Layout.minimumTarget)
                }
                .glassButton()
                .padding(Layout.spacing4)
                // Top-leading is also the first thing read on screen, so it is
                // first in the focus order as well.
                .accessibilityHint(returnTitle)
                .accessibilitySortPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A non-blocking degradation notice (stale cache, one rail failed).
struct NoticeBanner: View {
    let text: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Layout.spacing2) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption)
            Text(text)
                .font(Typography.metadata)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.accent.color)
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, Layout.spacing2)
        .background(theme.surfaceElevated.color(opacity: 0.7))
    }
}

/// The banner shown when the bundled catalog is standing in for the gateway.
struct DemoSourceBanner: View {
    let note: String
    let isLive: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Layout.spacing2) {
            Circle()
                .fill(isLive ? Color.green : theme.accent.color)
                .frame(width: 7, height: 7)
            Text(note)
                .font(Typography.metadata)
                .foregroundStyle(theme.textSecondary.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.spacing4)
        .padding(.vertical, 6)
        .background(theme.surface.color(opacity: 0.6))
        .accessibilityElement()
        .accessibilityLabel(isLive ? "Live data source: \(note)" : "Offline demo data: \(note)")
    }
}
