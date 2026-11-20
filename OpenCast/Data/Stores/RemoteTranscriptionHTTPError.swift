import Foundation
import OpenCastTranscription

/// `code` is the server's stable machine error string when one was decodable.
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
