import OpenCastPlayback
import SwiftUI

struct SleepTimerView: View {
    private static let extensionInterval: TimeInterval = 15 * 60

    @Environment(OpenCastAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var isEditingPresets = false

    var body: some View {
        let mode = appModel.playback.sleepTimerMode
        let options = SleepTimerOption.options(presets: appModel.playbackSettings.sleepTimerPresets)

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
                    ForEach(options) { option in
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit Presets", systemImage: "pencil", action: editPresets)
                }
            }
            .navigationDestination(isPresented: $isEditingPresets) {
                SettingsSleepTimerView()
            }
            .sensoryFeedback(.selection, trigger: mode)
        }
    }

    private func editPresets() {
        isEditingPresets = true
    }

    private func select(_ option: SleepTimerOption) {
        appModel.playback.setSleepTimer(mode: option.mode)
        dismiss()
    }

    private func extend() {
        appModel.playback.extendSleepTimer(by: Self.extensionInterval)
    }
}
