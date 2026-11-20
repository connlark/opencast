import SwiftUI

/// A SwiftUI `DragGesture` over the hero kept the Form from scrolling, even as a simultaneous
/// gesture. This pan declines to begin when the movement starts vertical, leaving it to the list.
struct SettingsAboutHeroYawRecognizer: UIGestureRecognizerRepresentable {
    let onChange: (_ translation: Double, _ releaseTranslation: Double) -> Void
    let onEnd: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            let translation = recognizer.translation(in: recognizer.view).x
            let velocity = recognizer.velocity(in: recognizer.view).x
            onChange(
                translation,
                SettingsAboutHeroYawGesture.releaseTranslation(translation: translation, velocity: velocity)
            )
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let velocity = pan.velocity(in: pan.view)
            return SettingsAboutHeroYawGesture.axis(for: CGSize(width: velocity.x, height: velocity.y)) == .horizontal
        }
    }
}
