import OpenCastPlayback
import SwiftUI

struct SleepTimerView: View {
    private static let extensionInterval: TimeInterval = 15 * 60

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let mode = appModel.playback.sleepTimerMode

        NavigationStack {
            List {
                if mode != .off {
                    Section {
                        SleepTimerRemainingRow()
                        if case .duration = mode {
                            Button("Add 15 Minutes", systemImage: "plus.circle", action: extend)
                        }
                    }
                }
                Section {
                    ForEach(SleepTimerOption.canonical) { option in
                        Button {
                            select(option)
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if option.mode == mode {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(option.mode == mode ? .isSelected : [])
                        .disabled(option.isEndOfEpisode && appModel.playback.duration == nil)
                    }
                }
            }
            .navigationTitle("Sleep Timer")
            .sensoryFeedback(.selection, trigger: mode)
        }
    }

    private func select(_ option: SleepTimerOption) {
        appModel.playback.setSleepTimer(mode: option.mode)
        dismiss()
    }

    private func extend() {
        appModel.playback.extendSleepTimer(by: Self.extensionInterval)
    }
}
