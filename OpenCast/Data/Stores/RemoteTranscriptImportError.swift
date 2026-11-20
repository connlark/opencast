import Foundation

nonisolated enum RemoteTranscriptImportError: Error, Equatable {
    /// A local run owns this episode; a remote import would race its record writes.
    case localTranscriptionActive
}
