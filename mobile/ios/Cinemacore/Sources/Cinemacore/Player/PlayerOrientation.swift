import UIKit

/// The process-wide orientation policy for the custom player.
///
/// `PlayerScreen` owns its own `AVPlayerLayer`, so it also owns rotation. UIKit
/// reads the mask from here through the app delegate, which keeps the delegate
/// and the request in `setFullscreen` from disagreeing.
///
/// `UIDevice.setValue(_:forKey:"orientation")` is deliberately absent: it is
/// undocumented, and `requestGeometryUpdate` has been the supported request
/// since iOS 16.
@MainActor
enum PlayerOrientation {
    private(set) static var isFullscreen = false

    /// The mask the app delegate reports to UIKit.
    ///
    /// iPad keeps every orientation in both modes: a tablet player fills the
    /// screen without having to rotate, and locking the app to landscape would
    /// break Split View and Stage Manager expectations.
    static var supportedOrientations: UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return .all }
        return isFullscreen ? .landscape : .allButUpsideDown
    }

    /// Applies the mode and, where the platform expects it, asks for a rotation.
    ///
    /// The request can be refused — a rotation lock, an inactive scene, or a
    /// window that is mid-transition — and that is a normal answer. Fullscreen
    /// still fills whatever orientation the device is in, so a refusal must not
    /// revert the state or trap.
    static func setFullscreen(_ value: Bool) {
        isFullscreen = value
        guard let scene = activeScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: value ? .landscape : .portrait)) { _ in
            // Deliberately ignored: see the refusal note above.
        }
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}
