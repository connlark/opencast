import Foundation
import OpenCastTranscription

struct EpisodeAdFreePassPresentation: Equatable {
    let stage: EpisodeAdFreePassStage
    let statusText: String
    let primaryActionTitle: String
    let isPrimaryActionEnabled: Bool

    static let idle = EpisodeAdFreePassPresentation(
        stage: .idle,
        statusText: "Ready to mark promos and ads.",
        primaryActionTitle: "Skip Promos & Ads",
        isPrimaryActionEnabled: true
    )

    static func awaitingModelConsent(byteCount: Int64) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .awaitingModelDownloadConsent(byteCount: byteCount),
            statusText: "Speech model needed. Download \(byteCountText(byteCount)) to continue.",
            primaryActionTitle: "Download Model (\(byteCountText(byteCount)))",
            isPrimaryActionEnabled: true
        )
    }

    static let downloadingEpisode = EpisodeAdFreePassPresentation(
        stage: .downloadingEpisode,
        statusText: "Downloading episode...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static func installingModel(_ progress: OpenCastWhisperModelInstallProgress) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .installingModel(progress),
            statusText: "Downloading speech model, \(byteCountText(progress.completedByteCount)) of \(byteCountText(progress.totalByteCount)).",
            primaryActionTitle: "Working...",
            isPrimaryActionEnabled: false
        )
    }

    static func installingSpeechAssets(fractionCompleted: Double) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .installingSpeechAssets(fractionCompleted: fractionCompleted),
            statusText: "Preparing speech assets...",
            primaryActionTitle: "Working...",
            isPrimaryActionEnabled: false
        )
    }

    static let checkingModel = EpisodeAdFreePassPresentation(
        stage: .unavailable("Checking speech model..."),
        statusText: "Checking speech model...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static let modelBusy = EpisodeAdFreePassPresentation(
        stage: .unavailable("Speech model is not ready."),
        statusText: "Speech model is not ready.",
        primaryActionTitle: "Skip Promos & Ads",
        isPrimaryActionEnabled: false
    )

    static func transcribing(_ progress: EpisodeTranscriptionProgress) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .transcribing(progress),
            statusText: "Transcribing - \(progress.completedDuration.formattedPlaybackDuration) of \(progress.audioDuration.formattedPlaybackDuration).",
            primaryActionTitle: "Working...",
            isPrimaryActionEnabled: false
        )
    }

    static let analyzing = EpisodeAdFreePassPresentation(
        stage: .analyzing,
        statusText: "Analyzing promos and ads...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static func completed(zoneCount: Int) -> EpisodeAdFreePassPresentation {
        let zoneText = zoneCount == 1 ? "1 zone marked." : "\(zoneCount) zones marked."
        return EpisodeAdFreePassPresentation(
            stage: .completed(zoneCount: zoneCount),
            statusText: zoneText,
            primaryActionTitle: "Reanalyze",
            isPrimaryActionEnabled: true
        )
    }

    static func queued(ahead: Int) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .idle,
            statusText: ahead > 0 ? "Queued — \(ahead) ahead" : "Queued",
            primaryActionTitle: "Queued",
            isPrimaryActionEnabled: false
        )
    }

    static let capDeferred = EpisodeAdFreePassPresentation(
        stage: .idle,
        statusText: "Daily detection limit reached — continues tomorrow",
        primaryActionTitle: "Retry",
        isPrimaryActionEnabled: true
    )

    static let outdated = EpisodeAdFreePassPresentation(
        stage: .idle,
        statusText: "Outdated — run again",
        primaryActionTitle: "Skip Promos & Ads",
        isPrimaryActionEnabled: true
    )

    static let interrupted = EpisodeAdFreePassPresentation(
        stage: .interrupted,
        statusText: "Transcript interrupted - tap to resume.",
        primaryActionTitle: "Resume",
        isPrimaryActionEnabled: true
    )

    static let pausedInBackground = EpisodeAdFreePassPresentation(
        stage: .interrupted,
        statusText: EpisodeTranscriptionStore.environmentalInterruptMessage,
        primaryActionTitle: "Resume",
        isPrimaryActionEnabled: true
    )

    static func failed(_ message: String) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .failed(message: message),
            statusText: message,
            primaryActionTitle: "Retry",
            isPrimaryActionEnabled: true
        )
    }

    static func unavailable(_ message: String) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .unavailable(message),
            statusText: message,
            primaryActionTitle: "Skip Promos & Ads",
            isPrimaryActionEnabled: false
        )
    }

    private static func byteCountText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
