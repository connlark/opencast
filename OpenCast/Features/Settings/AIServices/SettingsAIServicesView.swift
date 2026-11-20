import SwiftUI

struct SettingsAIServicesView: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        Form {
            SettingsAIServicesNoticeSection()
            SettingsAIServicesKeysSection()
            SettingsAIServicesProvidersSection()
            SettingsAIServicesUsageSection()
        }
        .settingsSubscreen(title: AIServicesCopy.screenTitle)
        .task {
            appModel.analysisUsage.refreshCurrentMonth()
            await appModel.analysisKeys.refreshPresences()
        }
    }
}

#Preview("Dark, Google Key") {
    NavigationStack {
        SettingsAIServicesView()
    }
    .environment(AIServicesPreviewSamples.appModel(savedProviders: [.google: true]))
    .preferredColorScheme(.dark)
}

#Preview("Light, No Keys") {
    NavigationStack {
        SettingsAIServicesView()
    }
    .environment(AIServicesPreviewSamples.appModel())
    .preferredColorScheme(.light)
}
