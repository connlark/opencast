import Foundation
import OpenCastTranscription

enum TranscriptionModelChoice: String, CaseIterable, Hashable, Identifiable, Sendable {
    // Raw values are persisted in LocalPreferenceRecord; do not rename.
    case fastTinyEnglish = "fastTinyEnglish"
    case accurateLargeV3 = "accurateLargeV3"

    static let defaultChoice: TranscriptionModelChoice = .fastTinyEnglish

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .fastTinyEnglish:
            "Fast"
        case .accurateLargeV3:
            "Accurate"
        }
    }

    var detail: String {
        switch self {
        case .fastTinyEnglish:
            "Downloaded tiny English model; fastest, lower accuracy."
        case .accurateLargeV3:
            "Downloaded large-v3 model; slower, higher accuracy."
        }
    }

    var model: OpenCastWhisperModel {
        switch self {
        case .fastTinyEnglish:
            .tinyEnglish
        case .accurateLargeV3:
            .largeV3
        }
    }

    var defaultVersion: String {
        model.defaultRemoteVersion
    }
}
