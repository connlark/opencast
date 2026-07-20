import Foundation
import Testing
@testable import OpenCastPlayback

@Suite("Streaming audio resource loader delegate")
struct StreamingAudioResourceLoaderDelegateTests {
    @Test("Superset network responses are sliced to the requested range")
    func supersetNetworkResponsesAreSlicedToRequestedRange() throws {
        let fetched = response(
            data: Data([0, 1, 2, 3, 4, 5]),
            range: 0..<6
        )

        let data = try StreamingAudioResourceLoaderDelegate.responseData(
            from: fetched,
            requestedRange: 2..<5
        )

        #expect(data == Data([2, 3, 4]))
    }

    @Test("Response slicing uses the fetched data start index")
    func responseSlicingUsesFetchedDataStartIndex() throws {
        let buffer = Data([8, 9, 0, 1, 2, 3, 4, 5])
        let fetched = response(data: buffer[2..<8], range: 0..<6)

        let data = try StreamingAudioResourceLoaderDelegate.responseData(
            from: fetched,
            requestedRange: 2..<4
        )

        #expect(data == Data([2, 3]))
    }

    @Test("Short responses at the requested upper bound remain valid")
    func shortResponsesAtRequestedUpperBoundRemainValid() throws {
        let fetched = response(data: Data([2, 3, 4]), range: 2..<5)

        let data = try StreamingAudioResourceLoaderDelegate.responseData(
            from: fetched,
            requestedRange: 2..<7
        )

        #expect(data == Data([2, 3, 4]))
    }

    @Test("Responses starting after the requested offset are rejected")
    func responsesStartingAfterRequestedOffsetAreRejected() {
        let fetched = response(data: Data([3, 4, 5, 6]), range: 3..<7)

        #expect(throws: StreamingAudioCacheError.invalidRange) {
            try StreamingAudioResourceLoaderDelegate.responseData(
                from: fetched,
                requestedRange: 2..<6
            )
        }
    }

    @Test("Responses whose bytes do not match their claimed range are rejected")
    func responsesWhoseBytesDoNotMatchClaimedRangeAreRejected() {
        let fetched = response(data: Data([0, 1, 2]), range: 0..<4)

        #expect(throws: StreamingAudioCacheError.invalidRange) {
            try StreamingAudioResourceLoaderDelegate.responseData(
                from: fetched,
                requestedRange: 0..<2
            )
        }
    }

    private func response(
        data: Data,
        range: Range<Int64>
    ) -> StreamingAudioRangeResponse {
        StreamingAudioRangeResponse(
            data: data,
            range: range,
            metadata: StreamingAudioRangeMetadata(
                contentLength: 8,
                mimeType: "audio/mpeg",
                etag: #""fixture""#,
                lastModified: nil,
                acceptsRanges: true,
                responseURL: URL(string: "https://example.com/audio.mp3")
            )
        )
    }
}
