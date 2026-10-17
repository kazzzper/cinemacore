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
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptyIcon)
            } description: {
                if let emptyMessage { Text(emptyMessage) }
            }

        case .failed(let error):
            ContentUnavailableView {
                Label("Something went wrong", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            } actions: {
                if error.isRetryable, let retry {
                    Button("Try Again") { Task { await retry() } }
                        .glassButton(prominent: true)
                }
            }

        case .locked(let error):
            ContentUnavailableView {
                Label("Not available", systemImage: "lock")
            } description: {
                Text(error.userMessage)
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
