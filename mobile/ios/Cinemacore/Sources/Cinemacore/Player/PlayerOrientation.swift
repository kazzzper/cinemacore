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
    /// The mask the app delegate reports to UIKit.
    ///
    /// Fullscreen deliberately does **not** narrow this to landscape. Turning
    /// the phone is how a viewer reaches the wide layout, so the mask has to
    /// keep permitting portrait — narrowing it is what refused the turn back and
    /// left the app sideways. The landscape request below is what turns the
    /// picture, not the mask.
    ///
    /// iPad keeps every orientation: a tablet player fills the screen without
    /// having to rotate, and locking it would break Split View and Stage Manager
    /// expectations.
    static var supportedOrientations: UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return .all }
        return .allButUpsideDown
    }

    /// Asks the window to turn, and never pretends it succeeded.
    ///
    /// The request can be refused — a rotation lock, an inactive scene, or a
    /// window that is mid-transition — and that is a normal answer. Fullscreen
    /// still fills whatever orientation the device is in, so a refusal must not
    /// revert the state or trap.
    ///
    /// `requestRotation` is false when the phone was turned by hand: the window
    /// is already landscape, and asking again for a rotation the device has
    /// performed is how a rotation ends up half-applied.
    static func setFullscreen(_ value: Bool, requestRotation: Bool = true) {
        guard requestRotation, let scene = activeScene else { return }
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
