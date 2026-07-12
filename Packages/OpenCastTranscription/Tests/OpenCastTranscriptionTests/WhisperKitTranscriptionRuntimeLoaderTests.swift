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

    @Test("Explicit compute profiles map to expected units")
    func explicitComputeProfilesMapToExpectedUnits() {
        let cpuOnly = OpenCastTranscriptionComputeProfile.cpuOnly.computeOptions
        #expect(cpuOnly.melCompute == .cpuOnly)
        #expect(cpuOnly.audioEncoderCompute == .cpuOnly)
        #expect(cpuOnly.textDecoderCompute == .cpuOnly)

        let cpuAndNeuralEngine = OpenCastTranscriptionComputeProfile.cpuAndNeuralEngine.computeOptions
        if WhisperKit.isRunningOnSimulator {
            #expect(cpuAndNeuralEngine.melCompute == .cpuOnly)
            #expect(cpuAndNeuralEngine.audioEncoderCompute == .cpuOnly)
            #expect(cpuAndNeuralEngine.textDecoderCompute == .cpuOnly)
        } else {
            #expect(cpuAndNeuralEngine.melCompute == .cpuAndNeuralEngine)
            #expect(cpuAndNeuralEngine.audioEncoderCompute == .cpuAndNeuralEngine)
            #expect(cpuAndNeuralEngine.textDecoderCompute == .cpuAndNeuralEngine)
        }
    }

    @Test("The whisperKitDefault profile restores GPU-backed mel on device")
    func whisperKitDefaultProfileRestoresGPUBackedMel() {
        let options = OpenCastTranscriptionComputeProfile.whisperKitDefault.computeOptions

        if WhisperKit.isRunningOnSimulator {
            #expect(options.melCompute == .cpuOnly)
            #expect(options.audioEncoderCompute == .cpuOnly)
            #expect(options.textDecoderCompute == .cpuOnly)
        } else {
            #expect(options.melCompute == .cpuAndGPU)
            #expect(options.audioEncoderCompute == .cpuAndNeuralEngine)
            #expect(options.textDecoderCompute == .cpuAndNeuralEngine)
        }
    }
}
