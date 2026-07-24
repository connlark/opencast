import Foundation
import OpenCastTranscription

struct EpisodeAdFreePassPresentation: Equatable {
    let stage: EpisodeAdFreePassStage
    let phase: EpisodeAdFreePassPresentationPhase
    let statusText: String
    let primaryActionTitle: String
    let isPrimaryActionEnabled: Bool

    static let idle = EpisodeAdFreePassPresentation(
        stage: .idle,
        phase: .idle,
        statusText: "Ready to mark promos and ads.",
        primaryActionTitle: "Skip Promos & Ads",
        isPrimaryActionEnabled: true
    )

    static func awaitingModelConsent(byteCount: Int64) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .awaitingModelDownloadConsent(byteCount: byteCount),
            phase: .idle,
            statusText: "Speech model needed. Download \(byteCountText(byteCount)) to continue.",
            primaryActionTitle: "Download Model (\(byteCountText(byteCount)))",
            isPrimaryActionEnabled: true
        )
    }

    static let downloadingEpisode = EpisodeAdFreePassPresentation(
        stage: .downloadingEpisode,
        phase: .running,
        statusText: "Downloading episode...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static func installingModel(_ progress: OpenCastWhisperModelInstallProgress) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .installingModel(progress),
            phase: .running,
            statusText: "Downloading speech model, \(byteCountText(progress.completedByteCount)) of \(byteCountText(progress.totalByteCount)).",
            primaryActionTitle: "Working...",
            isPrimaryActionEnabled: false
        )
    }

    static func installingSpeechAssets(fractionCompleted: Double) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .installingSpeechAssets(fractionCompleted: fractionCompleted),
            phase: .running,
            statusText: "Preparing speech assets...",
            primaryActionTitle: "Working...",
            isPrimaryActionEnabled: false
        )
    }

    static let checkingModel = EpisodeAdFreePassPresentation(
        stage: .unavailable("Checking speech model..."),
        phase: .checking,
        statusText: "Checking speech model...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static let modelBusy = EpisodeAdFreePassPresentation(
        stage: .unavailable("Speech model is not ready."),
        phase: .unavailable,
        statusText: "Speech model is not ready.",
        primaryActionTitle: "Skip Promos & Ads",
        isPrimaryActionEnabled: false
    )

    static func transcribing(_ progress: EpisodeTranscriptionProgress) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .transcribing(progress),
            phase: .running,
            statusText: "Transcribing - \(progress.completedDuration.formattedPlaybackDuration) of \(progress.audioDuration.formattedPlaybackDuration).",
            primaryActionTitle: "Working...",
            isPrimaryActionEnabled: false
        )
    }

    static let analyzing = EpisodeAdFreePassPresentation(
        stage: .analyzing,
        phase: .running,
        statusText: "Analyzing promos and ads...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static let checkingAnalysis = EpisodeAdFreePassPresentation(
        stage: .analyzing,
        phase: .checking,
        statusText: "Checking promo and ad markers...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static let cloudQueued = EpisodeAdFreePassPresentation(
        stage: .cloudQueued,
        phase: .running,
        statusText: "Detecting in the cloud...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static func cloudTranscribing(
        _ progress: RemoteTranscriptionActiveProgress?
    ) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .cloudTranscribing(progress),
            phase: .running,
            statusText: progress?.estimate.map { "Transcribing on the server — \($0.displayText)" }
                ?? "Transcribing on the server...",
            primaryActionTitle: "Working...",
            isPrimaryActionEnabled: false
        )
    }

    static let cloudDetectingAds = EpisodeAdFreePassPresentation(
        stage: .cloudDetectingAds,
        phase: .running,
        statusText: "Detecting promos and ads...",
        primaryActionTitle: "Working...",
        isPrimaryActionEnabled: false
    )

    static func cloudUnavailable(_ message: String) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .cloudUnavailable(message: message),
            phase: .failed,
            statusText: message,
            primaryActionTitle: "Detect on Device",
            isPrimaryActionEnabled: true
        )
    }

    static func completed(zoneCount: Int) -> EpisodeAdFreePassPresentation {
        let zoneText = zoneCount == 1 ? "1 zone marked." : "\(zoneCount) zones marked."
        return EpisodeAdFreePassPresentation(
            stage: .completed(zoneCount: zoneCount),
            phase: .completed,
            statusText: zoneText,
            primaryActionTitle: "Reanalyze",
            isPrimaryActionEnabled: true
        )
    }

    static func queued(ahead: Int) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .idle,
            phase: .queued,
            statusText: ahead > 0 ? "Queued — \(ahead) ahead" : "Queued",
            primaryActionTitle: "Queued",
            isPrimaryActionEnabled: false
        )
    }

    static let capDeferred = EpisodeAdFreePassPresentation(
        stage: .idle,
        phase: .deferred,
        statusText: "Daily detection limit reached — continues tomorrow",
        primaryActionTitle: "Retry",
        isPrimaryActionEnabled: true
    )

    static let outdated = EpisodeAdFreePassPresentation(
        stage: .idle,
        phase: .idle,
        statusText: "Outdated — run again",
        primaryActionTitle: "Skip Promos & Ads",
        isPrimaryActionEnabled: true
    )

    static let interrupted = EpisodeAdFreePassPresentation(
        stage: .interrupted,
        phase: .failed,
        statusText: "Transcript interrupted - tap to resume.",
        primaryActionTitle: "Resume",
        isPrimaryActionEnabled: true
    )

    static let pausedInBackground = EpisodeAdFreePassPresentation(
        stage: .interrupted,
        phase: .failed,
        statusText: EpisodeTranscriptionStore.environmentalInterruptMessage,
        primaryActionTitle: "Resume",
        isPrimaryActionEnabled: true
    )

    static func failed(_ message: String) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .failed(message: message),
            phase: .failed,
            statusText: message,
            primaryActionTitle: "Retry",
            isPrimaryActionEnabled: true
        )
    }

    static func unavailable(_ message: String) -> EpisodeAdFreePassPresentation {
        EpisodeAdFreePassPresentation(
            stage: .unavailable(message),
            phase: .unavailable,
            statusText: message,
            primaryActionTitle: "Skip Promos & Ads",
            isPrimaryActionEnabled: false
        )
    }

    private static func byteCountText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
