#if DEBUG
import OpenCastTranscription

struct OpenCastUITestCompletingEpisodeTranscriber: EpisodeTranscribing {
    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        AsyncThrowingStream { continuation in
            let segment = OpenCastTranscriptSegment(
                id: 0,
                start: request.resumeStart ?? 0,
                end: (request.resumeStart ?? 0) + 3,
                text: "Deterministic UI request transcript.",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
            continuation.yield(.finished(OpenCastTranscriptionResult(
                modelIdentifier: request.modelIdentifier,
                languageCode: request.languageCode,
                text: segment.text,
                segments: [segment],
                timings: OpenCastTranscriptionTimings(
                    audioDuration: 300,
                    modelLoading: 0,
                    audioLoading: 0,
                    transcription: 1,
                    fullPipeline: 1,
                    realTimeFactor: 0.01,
                    decodingFallbackCount: 0,
                    decodingFallback: 0,
                    decodingWindowCount: 1
                )
            )))
            continuation.finish()
        }
    }

    func unload() async {}
}
#endif
