import CoreML
@preconcurrency import WhisperKit

struct StubFeatureExtracting: FeatureExtracting {
    let melCount: Int? = 80
    let windowSamples: Int? = 16000

    func logMelSpectrogram(fromAudio inputAudio: any AudioProcessorOutputType) async throws -> (any FeatureExtractorOutputType)? {
        try MLMultiArray(shape: [1], dataType: .float16)
    }
}
