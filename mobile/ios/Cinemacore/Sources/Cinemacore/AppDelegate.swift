import UIKit

/// Hosts the background-session callbacks SwiftUI's `App` lifecycle has no
/// place for.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundDownloads.shared.bootstrap()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundDownloads.shared.handleEvents(
            for: identifier,
            completionHandler: completionHandler
        )
    }

    /// Rotation belongs to the player while it is fullscreen, and to the app's
    /// normal portrait-and-landscape policy otherwise. `PlayerOrientation` owns
    /// the policy so the request and this answer cannot drift apart.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlayerOrientation.supportedOrientations
    }
}
