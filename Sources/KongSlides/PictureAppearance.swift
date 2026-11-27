import Foundation
import CoreGraphics

struct PictureAppearance: Codable, Equatable {
    var angle = 0.0
    var opacity = 1.0
    var flipHorizontal = false
    var flipVertical = false

    var isValid: Bool { (-360...360).contains(angle) && (0...1).contains(opacity) }

    // The object model uses a top-left origin; Core Graphics uses a bottom-left origin.
    var clockwiseRadians: CGFloat { CGFloat(angle * .pi / 180) }

    func bounds(of frame: CGRect) -> CGRect {
        guard angle != 0 else { return frame }
        let transform = CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: clockwiseRadians).translatedBy(x: -frame.midX, y: -frame.midY)
        return frame.applying(transform)
    }
}
