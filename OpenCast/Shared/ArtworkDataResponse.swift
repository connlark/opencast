import Foundation
import OpenCastCore

nonisolated struct ArtworkDataResponse: Sendable {
    var data: Data
    var response: OpenCastHTTPResponse
}
