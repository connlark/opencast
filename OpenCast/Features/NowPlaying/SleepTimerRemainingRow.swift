import SwiftUI

struct SleepTimerRemainingRow: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LabeledContent(
                "Remaining",
                value: SleepTimerRemainingText.text(for: appModel.playback, at: context.date)
            )
        }
    }
}
