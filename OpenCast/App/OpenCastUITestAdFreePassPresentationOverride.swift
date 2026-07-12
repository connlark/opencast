import Foundation
import OpenCastTranscription

enum OpenCastUITestAdFreePassPresentationOverride {
    static let environmentKey = "OPENCAST_UI_TEST_AD_FREE_PASS_STAGE"

    static func resolve(environment: [String: String]) -> EpisodeAdFreePassPresentation? {
        guard let rawValue = environment[environmentKey]?.trimmedNonEmpty else {
            return nil
        }

        switch rawValue.lowercased().replacing("_", with: "-") {
        case "idle":
            return .idle
        case "consent", "model-consent":
            return .awaitingModelConsent(byteCount: 78_900_000)
        case "downloading":
            return .downloadingEpisode
        case "installing":
            return .installingModel(OpenCastWhisperModelInstallProgress(
                modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
                version: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
                completedFileCount: 2,
                totalFileCount: 5,
                completedByteCount: 24_000_000,
                totalByteCount: 78_900_000,
                currentFilePath: "model.bin"
            ))
        case "checking":
            return .checkingModel
        case "model-busy", "busy":
            return .modelBusy
        case "transcribing":
            return .transcribing(EpisodeTranscriptionProgress(
                audioDuration: 180,
                completedDuration: 64,
                checkpointCount: 3,
                currentWindowIndex: 2,
                currentText: "Seed Sponsor"
            ))
        case "analyzing":
            return .analyzing
        case "completed":
            return .completed(zoneCount: 2)
        case "outdated":
            return .outdated
        case "interrupted":
            return .interrupted
        case "failed":
            return .failed("Daily promo/ad analysis limit reached.")
        case "unavailable":
            return .unavailable("No episode playing.")
        default:
            return nil
        }
    }
}
