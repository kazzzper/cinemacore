import SwiftUI
import CinemacoreCore

/// The overlay gates the app can present: region lockout, forced update, the
/// optional update prompt, and the community prompt.
///
/// `LabScreen` can raise them on demand, which is the only way to review them
/// until a live gateway can actually demand them.
enum GatePreview: String, CaseIterable, Identifiable {
    case lockout
    case forceUpdate
    case appUpdate
    case joinCommunity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockout: "Region lockout"
        case .forceUpdate: "Forced update"
        case .appUpdate: "Optional update"
        case .joinCommunity: "Community prompt"
        }
    }

    var systemImage: String {
        switch self {
        case .lockout: "lock.shield"
        case .forceUpdate: "arrow.down.app"
        case .appUpdate: "sparkles"
        case .joinCommunity: "person.3"
        }
    }

    /// The dismissible gates present as sheets; the other two are takeovers and
    /// have to stay in an overlay.
    var isModalSheet: Bool {
        switch self {
        case .lockout, .forceUpdate: false
        case .appUpdate, .joinCommunity: true
        }
    }
}

/// The optional update prompt.
///
/// Distinct from ``ForceUpdateScreen``: this one is dismissible, because a
/// non-blocking upgrade is a suggestion and the user is allowed to decline it.
struct AppUpdateDialog: View {
    let onDismiss: () -> Void
    var version: String = "0.2.0"
    var notes: [String] = [
        "Faster poster loading",
        "Subtitle offset control",
        "Fixes playback resume on series",
    ]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing4) {
            HStack(spacing: Layout.spacing3) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(theme.accent.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available")
                        .font(Typography.sectionTitle)
                        .foregroundStyle(theme.textPrimary.color)
                    Text("Version \(version)")
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(theme.textSecondary.color)
                        Text(note)
                            .font(Typography.body)
                            .foregroundStyle(theme.textSecondary.color)
                    }
                }
            }

            HStack(spacing: Layout.spacing2) {
                Button("Not now", action: onDismiss)
                    .glassButton()
                Button("Update") { onDismiss() }
                    .glassButton(prominent: true)
            }
        }
        .padding(Layout.spacing5)
        .presentationDetents([.height(340)])
        .presentationBackground(.regularMaterial)
    }
}

/// Shown when the gateway refuses this region or device.
///
/// Deliberately offers no retry: the state is not transient, and a retry button
/// would let the user believe otherwise.
struct LockoutScreen: View {
    var onDismiss: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            VStack(spacing: Layout.spacing5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 52))
                    .foregroundStyle(theme.brand.color)

                Text("Not available here")
                    .font(Typography.screenTitle)
                    .foregroundStyle(theme.textPrimary.color)

                Text(
                    "Cinemacore can't reach the catalog from this region or device. "
                    + "If you're using a VPN, try reconnecting to a supported region."
                )
                .font(Typography.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Layout.spacing6)

                if let onDismiss {
                    Button("Back", action: onDismiss)
                        .glassButton()
                }
            }
        }
    }
}

/// Shown when the installed build is below the provider's minimum.
struct ForceUpdateScreen: View {
    var onDismiss: (() -> Void)?
    var storeURL: URL?

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            VStack(spacing: Layout.spacing5) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 52))
                    .foregroundStyle(theme.accent.color)

                Text("Update required")
                    .font(Typography.screenTitle)
                    .foregroundStyle(theme.textPrimary.color)

                Text("This version is no longer supported. Update to keep watching.")
                    .font(Typography.body)
                    .foregroundStyle(theme.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Layout.spacing6)

                if let storeURL {
                    Link("Update", destination: storeURL)
                        .glassButton(prominent: true)
                }
                if let onDismiss {
                    Button("Not now", action: onDismiss)
                        .font(Typography.metadata)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
        }
    }
}

/// The periodic community prompt.
struct JoinCommunitySheet: View {
    let onDismiss: () -> Void
    /// The provider's community channel, the same invite the Genga-World build
    /// opens from its own prompt.
    var communityURL: URL? = URL(string: "https://t.me/Gengaworldofficial")

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Layout.spacing5) {
            Image(systemName: "person.3")
                .font(.system(size: 44))
                .foregroundStyle(theme.brand.color)

            Text("Join the community")
                .font(Typography.sectionTitle)
                .foregroundStyle(theme.textPrimary.color)

            Text("Get release notes, report a broken stream, and request titles.")
                .font(Typography.body)
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)

            VStack(spacing: Layout.spacing2) {
                Button("Join on Telegram") {
                    if let communityURL {
                        openURL(communityURL)
                    }
                    onDismiss()
                }
                .glassButton(prominent: true)

                Button("Maybe later", action: onDismiss)
                    .font(Typography.metadata)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(Layout.spacing6)
        .presentationDetents([.height(340)])
        .presentationBackground(.regularMaterial)
    }
}
