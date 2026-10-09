import SwiftUI

/// Scoped to one episode by the host's identity. Hidden events are consumed
/// without replaying feedback when the prepared card becomes visible again.
struct NowPlayingAutoSkipFeedbackView: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pinsAppStoreAutoSkipPill) private var pinsAutoSkipPill
    @State private var feedback = 0
    @State private var showsPill = false

    var body: some View {
        ZStack {
            if showsPill || pinsAutoSkipPill {
                NowPlayingAutoSkipPill(onUndo: undoLastAutoSkip)
                    .transition(.opacity)
                    .offset(y: reduceMotion ? 0 : -28)
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: feedback)
        .onChange(of: appModel.playback.lastAutoSkipEvent, initial: true) { _, event in
            guard event != nil, appModel.isNowPlayingPresented else { return }
            feedback += 1
            AccessibilityNotification.Announcement("Skipped promo").post()
            withAnimation(.easeOut(duration: 0.16)) { showsPill = true }
        }
        .onChange(of: appModel.isNowPlayingPresented) { _, isPresented in
            if !isPresented {
                withTransaction(\.disablesAnimations, true) { showsPill = false }
            }
        }
        .task(id: feedback) {
            guard feedback > 0 else { return }
            do {
                try await Task.sleep(for: .milliseconds(2500))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            withAnimation(.easeOut(duration: 0.2)) { showsPill = false }
        }
    }

    private func undoLastAutoSkip() {
        appModel.undoLastAutoSkip()
        withAnimation(.easeOut(duration: 0.2)) { showsPill = false }
    }
}
