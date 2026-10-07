import SwiftUI

/// The About hero's drag-to-turn. A SwiftUI `DragGesture` over the hero kept
/// the Form from scrolling even as a simultaneous gesture; this pan declines
/// to begin when the movement starts vertical, which leaves it to the list.
struct SettingsAboutHeroYawRecognizer: UIGestureRecognizerRepresentable {
    /// The live horizontal translation and where a release would carry it.
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
