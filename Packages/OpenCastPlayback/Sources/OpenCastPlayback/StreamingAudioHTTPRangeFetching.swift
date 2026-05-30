import Foundation

nonisolated protocol StreamingAudioHTTPRangeFetching: Sendable {
    func data(for url: URL, range: Range<Int64>) async throws -> StreamingAudioRangeResponse
}
