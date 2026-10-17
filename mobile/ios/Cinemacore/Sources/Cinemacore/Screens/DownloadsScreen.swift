import SwiftUI
import CinemacoreCore

/// Offline downloads.
///
/// Downloads are not yet wired to real media (the provider's protected streams
/// need the fetch layer from T-005), so this screen states that plainly instead
/// of implying files are being saved.
struct DownloadsScreen: View {
    let app: AppModel

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.color.ignoresSafeArea()

            ContentUnavailableView {
                Label("Downloads arrive with the media layer", systemImage: "arrow.down.circle")
            } description: {
                Text(
                    "Offline playback needs the signed-header fetch path. Until that "
                    + "lands, play from the detail screen while online."
                )
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}
