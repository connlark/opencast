import SwiftData
import SwiftUI

/// One Skip Sound choice; nil is None. A tap chooses it, and a sound plays
/// once, also when it is already the choice.
struct SkipSoundOptionRow: View {
    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let sound: SkipSound?
    let onChoose: () -> Void

    private var isSelected: Bool {
        appModel.playbackSettings.autoSkipSound == sound
    }

    var body: some View {
        Button(action: choose) {
            HStack {
                Text(sound?.name ?? "None")
                    .foregroundStyle(Color.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityIdentifier("skip-sound-option-\(sound?.id ?? "none")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose() {
        onChoose()
        appModel.setAutoSkipSound(sound, modelContext: modelContext)
    }
}
