import Foundation
import OpenCastTranscription

/// The file-store operations the shared analysis record machinery needs;
/// both analysis file stores conform.
nonisolated protocol AnalysisDocumentFileStore: Sendable {
    var baseDirectory: URL { get }
    func documentExists(relativePath: String?) -> Bool
    func documentDecodes(relativePath: String) -> Bool
    func delete(relativePath: String?) throws
    func transcriptFingerprint(for document: EpisodeTranscriptDocument) -> String
}
