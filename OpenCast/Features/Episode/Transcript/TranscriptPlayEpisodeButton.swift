import SwiftUI

struct TranscriptPlayEpisodeButton: View {
    let action: () -> Void

    @State private var playFeedback = 0

    var body: some View {
        Button("Play Episode", systemImage: "play.fill", action: play)
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .sensoryFeedback(.impact(flexibility: .soft), trigger: playFeedback)
    }

    private func play() {
        playFeedback += 1
        action()
    }
}
