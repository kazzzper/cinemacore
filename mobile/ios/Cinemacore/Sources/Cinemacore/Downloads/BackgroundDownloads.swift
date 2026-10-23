import Foundation
import CinemacoreCore

/// Owns the one background `URLSession` this process may create.
///
/// `BackgroundURLSessionTransfer` is deliberately process-lifetime: a second
/// session with the same identifier would split delegate callbacks and strand
/// the daemon's tasks, so launch and wake-up both enter through this singleton.
@MainActor
final class BackgroundDownloads {
    static let shared = BackgroundDownloads()

    let transfer: BackgroundURLSessionTransfer

    private let identifier: String

    private init(
        identifier: String = BackgroundURLSessionTransfer.defaultIdentifier,
        stagingDirectory: URL = CinemacoreApp.downloadsDirectory
            .appendingPathComponent(".staging", isDirectory: true)
    ) {
        self.identifier = identifier
        self.transfer = BackgroundURLSessionTransfer(
            stagingDirectory: stagingDirectory,
            identifier: identifier
        )
    }

    /// Brings the session up at launch, before the daemon can deliver an event
    /// to a session that does not exist yet.
    func bootstrap() {
        _ = transfer
    }

    func handleEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == self.identifier else {
            // This process never created that session, so it will not receive
            // `urlSessionDidFinishEvents`. Acknowledge now or iOS keeps the
            // relaunch waiting for a handler we can never call.
            completionHandler()
            return
        }
        transfer.storeBackgroundCompletionHandler(completionHandler)
    }
}
