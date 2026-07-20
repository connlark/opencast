import Foundation
import OpenCastTranscription

/// Transport-level failure from the remote transcription worker. `code`
/// carries the server's stable machine error string when one was decodable.
nonisolated struct RemoteTranscriptionHTTPError: Error, Equatable {
    let statusCode: Int
    let code: String
    let detail: String?

    var errorCode: OpenCastRemoteTranscriptionErrorCode {
        OpenCastRemoteTranscriptionErrorCode(wireValue: code)
    }
}

nonisolated struct RemoteTranscriptionAPIErrorResponse: Decodable {
    let error: String
    let detail: String?
}
