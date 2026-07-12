import Foundation

struct OpenCastRemoteModelResponse: Sendable, Equatable {
    var statusCode: Int?

    var isSuccessfulHTTPResponse: Bool {
        guard let statusCode else {
            return false
        }
        return 200..<300 ~= statusCode
    }
}
