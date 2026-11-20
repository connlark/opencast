import Foundation

enum EpisodePipelineAction: Equatable {
    case cancelPass
    case cancelDownload
    case cancelTranscription
    case downloadModel(byteCount: Int64?)
    case resumeQueue
    case resumeDownload
    case resumeTranscription
    case retryPass
    case retryDownload
    case retryTranscription
    case retryAnalysis
    case removeFromQueue
    case detectOnDevice

    var title: String {
        switch self {
        case .cancelPass, .cancelDownload, .cancelTranscription:
            "Cancel"
        case .downloadModel(let byteCount):
            if let byteCount {
                "Download Model (\(byteCount.formatted(.byteCount(style: .file))))"
            } else {
                "Download Model"
            }
        case .resumeQueue, .resumeDownload, .resumeTranscription:
            "Resume"
        case .retryPass, .retryDownload, .retryTranscription, .retryAnalysis:
            "Retry"
        case .removeFromQueue:
            "Remove from Queue"
        case .detectOnDevice:
            "Detect on This Device"
        }
    }
}
