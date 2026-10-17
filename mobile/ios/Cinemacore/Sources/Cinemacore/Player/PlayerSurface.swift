import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Draws the player's video without `AVKit`'s controls.
///
/// The backing layer *is* the player layer, so the video follows the SwiftUI
/// layout with no frame bookkeeping — and picture-in-picture, which can only
/// adopt an `AVPlayerLayer`, gets the very layer on screen.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Fill crops the frame to the edges; fit letterboxes it.
    var fillsScreen = false
    /// Handed the live layer, which exists only inside the representable.
    var onLayerReady: (AVPlayerLayer) -> Void = { _ in }

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer?.player = player
        view.playerLayer?.videoGravity = gravity
        if let layer = view.playerLayer { onLayerReady(layer) }
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        view.playerLayer?.player = player
        view.playerLayer?.videoGravity = gravity
    }

    private var gravity: AVLayerVideoGravity {
        fillsScreen ? .resizeAspectFill : .resizeAspect
    }
}

/// A view whose backing layer *is* the player layer.
///
/// Not `private`: the representable that returns it is module-visible, and a
/// `private` return type cannot appear in its signature. Nothing outside this
/// file should name it.
final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}

/// The system AirPlay picker.
///
/// Hand-rolled route selection is not possible on iOS — the picker owns the
/// route list and the hand-off to the receiver — so this wraps the real one
/// rather than pretending to enumerate devices.
struct AirPlayRoutePicker: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        apply(tint, to: view)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        apply(tint, to: view)
    }

    private func apply(_ tint: Color, to view: AVRoutePickerView) {
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(tint)
    }
}
