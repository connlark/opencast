@testable import OpenCastTranscription
import Testing
@preconcurrency import WhisperKit

@Suite("WhisperKit transcription runtime loader")
struct WhisperKitTranscriptionRuntimeLoaderTests {
    @Test("Default compute options avoid GPU-backed mel for background safety")
    func defaultComputeOptionsAvoidGPUBackedMel() {
        let options = WhisperKitTranscriptionRuntimeLoader.backgroundSafeComputeOptions

        if WhisperKit.isRunningOnSimulator {
            #expect(options.melCompute == .cpuOnly)
            #expect(options.audioEncoderCompute == .cpuOnly)
            #expect(options.textDecoderCompute == .cpuOnly)
        } else {
            #expect(options.melCompute == .cpuAndNeuralEngine)
            #expect(options.audioEncoderCompute == .cpuAndNeuralEngine)
            #expect(options.textDecoderCompute == .cpuAndNeuralEngine)
        }
    }
}
