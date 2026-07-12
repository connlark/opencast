import OpenCastTranscription
@testable import OpenCast

@MainActor
final class EpisodeTranscriptionRequestTestTranscriber: EpisodeTranscribing, @unchecked Sendable {
    typealias StreamBuilder = @MainActor (
        EpisodeTranscriptionRunRequest,
        Int
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>

    private let streamBuilder: StreamBuilder
    private(set) var requests: [EpisodeTranscriptionRunRequest] = []

    init(streamBuilder: @escaping StreamBuilder) {
        self.streamBuilder = streamBuilder
    }

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        requests.append(request)
        return streamBuilder(request, requests.count)
    }

    func unload() async {}
}
