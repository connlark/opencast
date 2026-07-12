import CoreML
@preconcurrency import WhisperKit

struct StubAudioEncoding: AudioEncoding {
    let embedSize: Int? = 4

    func encodeFeatures(_ features: any FeatureExtractorOutputType) async throws -> (any AudioEncoderOutputType)? {
        try MLMultiArray(shape: [1], dataType: .float16)
    }
}
