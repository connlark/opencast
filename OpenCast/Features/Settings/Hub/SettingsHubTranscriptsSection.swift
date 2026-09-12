import SwiftUI

struct SettingsHubTranscriptsSection: View {
    @Environment(OpenCastAppModel.self) private var appModel

    var body: some View {
        Section("Transcripts & Ads") {
            SettingsNavigationRow(
                title: "Transcription",
                systemImage: "waveform",
                route: .transcription,
                value: transcriptionValue
            )
            SettingsNavigationRow(
                title: "Ad Skipping",
                systemImage: "forward.end",
                route: .adSkipping,
                value: adSkippingValue
            )
            SettingsNavigationRow(
                title: "Credits",
                systemImage: "creditcard",
                route: .credits,
                value: creditsValue
            )
        }
    }

    private var transcriptionValue: String {
        if appModel.transcriptionEngineSettings.prefersAppleSpeech,
           appModel.appleSpeechAssets.isTranscriberAvailable {
            return "Apple"
        }
        return "Whisper \(appModel.transcriptionModels.selectedChoice.title)"
    }

    private var adSkippingValue: String {
        switch appModel.adDetectionSettings.mode {
        case nil:
            "Ask"
        case .onDevice:
            "On Device"
        case .cloud:
            "Cloud"
        }
    }

    private var creditsValue: String? {
        appModel.remoteTranscriptionPurchases.balance.map {
            RemoteTranscriptionBalanceFormatting.hours($0.availableSeconds)
        }
    }
}
