import Foundation

enum EpisodePipelineStepKind: CaseIterable, Hashable {
    case download
    case transcribe
    case detectAds

    var title: String {
        switch self {
        case .download:
            "Download"
        case .transcribe:
            "Transcribe"
        case .detectAds:
            "Detect Ads"
        }
    }

    var systemImage: String {
        switch self {
        case .download:
            "arrow.down.circle"
        case .transcribe:
            "text.quote"
        case .detectAds:
            "megaphone"
        }
    }
}
