import Foundation

nonisolated struct StreamingAudioRangeResponse: Equatable, Sendable {
    var data: Data
    var range: Range<Int64>
    var metadata: StreamingAudioRangeMetadata
}
