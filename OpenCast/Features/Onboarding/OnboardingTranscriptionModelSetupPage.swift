import SwiftUI

struct OnboardingTranscriptionModelSetupPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let selectedChoice: TranscriptionModelChoice
    let modelState: TranscriptionModelState
    let onInstall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tiny Whisper Model")
                        .font(.largeTitle)
                        .bold()

                    Text("Install the tiny English speech model now so transcripts and promo/ad tools are ready later. It is about 75 MB and stays on this device.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle)
                                .font(.headline)

                            Text(statusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } icon: {
                        WhisperModelInstallWaveformView(
                            isAnimating: isModelInstalling,
                            reduceMotion: reduceMotion
                        )
                    }
                    .accessibilityElement(children: .combine)

                    if showsInstallButton {
                        Button(action: onInstall) {
                            Label(installButtonTitle, systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("Install Tiny Whisper Model")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 12) {
                    OnboardingPitchRow(
                        systemImage: "bolt.fill",
                        title: "Fast setup",
                        message: "Small download, quick first transcripts."
                    )

                    OnboardingPitchRow(
                        systemImage: "lock.fill",
                        title: "On device",
                        message: "Speech processing stays local when you transcribe."
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.visible)
        .accessibilityIdentifier("Tiny Whisper Onboarding")
    }

    private var statusTitle: String {
        switch modelState {
        case .unknown:
            "Model status unknown"
        case .notInstalled:
            "Ready to install"
        case .checking:
            "Checking model"
        case .installing:
            "Installing in the background"
        case .installed:
            selectedChoice == .fastTinyEnglish ? "Tiny model ready" : "\(selectedChoice.title) model ready"
        case .repairAvailable:
            "Model needs repair"
        case .deleting:
            "Deleting model"
        case .failed:
            "Model issue"
        }
    }

    private var statusMessage: String {
        switch modelState {
        case .unknown:
            "Install checks will run before the download starts."
        case .notInstalled:
            "Tap install to start the Tiny Whisper download, then keep going."
        case .checking:
            "opencast is checking the signed model manifest."
        case .installing:
            "You can continue onboarding while the speech model downloads."
        case .installed:
            "You can continue. Transcripts are ready when you download an episode."
        case .repairAvailable:
            "The installed receipt needs a fresh install before transcription runs."
        case .deleting:
            "Wait for the current model operation to finish before installing."
        case .failed(let message):
            message
        }
    }

    private var isModelInstalling: Bool {
        if case .installing = modelState {
            return true
        }

        return false
    }

    private var showsInstallButton: Bool {
        switch modelState {
        case .checking, .installing, .deleting:
            false
        case .installed:
            selectedChoice != .fastTinyEnglish
        case .unknown, .notInstalled, .repairAvailable, .failed:
            true
        }
    }

    private var installButtonTitle: String {
        if case .repairAvailable = modelState, selectedChoice == .fastTinyEnglish {
            return "Repair Tiny Model"
        }

        return "Install Tiny Model"
    }
}
