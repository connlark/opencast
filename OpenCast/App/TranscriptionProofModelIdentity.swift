#if DEBUG
import Foundation
import OpenCastTranscription

nonisolated struct TranscriptionProofModelIdentity: Sendable, Equatable {
    var identifier: String
    var version: String
    var treeSHA256: String
    var byteCount: Int64?

    init(
        identifier: String,
        version: String,
        treeSHA256: String,
        byteCount: Int64?
    ) {
        self.identifier = identifier
        self.version = version
        self.treeSHA256 = treeSHA256
        self.byteCount = byteCount
    }

    init(summary: OpenCastWhisperModelInstalledSummary) {
        identifier = summary.modelIdentifier
        version = summary.version
        treeSHA256 = summary.treeSHA256
        byteCount = summary.totalByteCount
    }
}
#endif
