import RealityKit
import SwiftUI

struct SettingsAboutGlassHeroView: View {
    let model: SettingsAboutHeroModel
    let animated: Bool

    @State private var firstFrame = SettingsAboutHeroFirstFrame()

    var body: some View {
        ZStack {
            // Out of the tree once drawn: left in at opacity 0 beside the
            // RealityView, it surfaced as a second accessibility element.
            if !firstFrame.hasRendered {
                SettingsAboutHeroImage()
                    .transition(.opacity)
            }

            RealityView { content in
                content.camera = .virtual
                guard let stage = model.stage else {
                    return
                }
                stage.removeFromParent()
                content.add(stage)
                firstFrame.watch(content)
                model.playEntranceIfNeeded(animated: animated)
            } placeholder: {
                Color.clear
            }
            // Touches belong to the yaw recognizer and the Form, never RealityKit.
            .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.2), value: firstFrame.hasRendered)
        .contentShape(.rect)
        .gesture(SettingsAboutHeroYawRecognizer(onChange: followDrag, onEnd: endDrag))
    }

    private func followDrag(translation: Double, releaseTranslation: Double) {
        model.dragTurn(
            offset: SettingsAboutHeroYawGesture.offset(forHorizontalTranslation: translation),
            releaseOffset: SettingsAboutHeroYawGesture.offset(forHorizontalTranslation: releaseTranslation)
        )
    }

    private func endDrag() {
        model.endDragTurn(animated: animated)
    }
}
