import Foundation

nonisolated enum RemoteTranscriptImportError: Error, Equatable {
    /// A local transcription run owns this episode; remote import would race
    /// its record writes. The caller retries after the run stops.
    case localTranscriptionActive
}
