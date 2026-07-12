import Foundation
import OpenCastTranscription

struct EpisodeTranscriptionModelIdentity: Sendable, Equatable {
    var modelIdentifier: String
    var version: String
    var treeSHA256: String

    init(
        modelIdentifier: String,
        version: String,
        treeSHA256: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.version = version
        self.treeSHA256 = treeSHA256
    }

    init(summary: OpenCastWhisperModelInstalledSummary) {
        modelIdentifier = summary.modelIdentifier
        version = summary.version
        treeSHA256 = summary.treeSHA256
    }
}
