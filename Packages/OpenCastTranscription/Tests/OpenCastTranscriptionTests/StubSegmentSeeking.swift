import CoreML
@preconcurrency import WhisperKit

/// Always consumes the full window and reports one segment for it.
struct StubSegmentSeeking: SegmentSeeking {
    func findSeekPointAndSegments(
        decodingResult: DecodingResult,
        options: DecodingOptions,
        allSegmentsCount: Int,
        currentSeek seek: Int,
        segmentSize: Int,
        sampleRate: Int,
        timeToken: Int,
        specialToken: Int,
        tokenizer: any WhisperTokenizer
    ) -> (Int, [TranscriptionSegment]?) {
        let segment = TranscriptionSegment(
            id: allSegmentsCount,
            seek: seek,
            start: Float(seek) / Float(sampleRate),
            end: Float(seek + segmentSize) / Float(sampleRate),
            text: " stub",
            tokens: [1]
        )
        return (seek + segmentSize, [segment])
    }

    func addWordTimestamps(
        segments: [TranscriptionSegment],
        alignmentWeights: MLMultiArray,
        tokenizer: any WhisperTokenizer,
        seek: Int,
        segmentSize: Int,
        prependPunctuations: String,
        appendPunctuations: String,
        lastSpeechTimestamp: Float,
        options: DecodingOptions,
        timings: TranscriptionTimings
    ) throws -> [TranscriptionSegment]? {
        segments
    }
}
