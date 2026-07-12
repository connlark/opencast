import Foundation
@preconcurrency import WhisperKit

struct WhisperKitTranscriptionRuntimeLoader: OpenCastTranscriptionRuntimeLoading {
    static let backgroundSafeComputeOptions: ModelComputeOptions = {
        if WhisperKit.isRunningOnSimulator {
            return ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly
            )
        }

        return ModelComputeOptions(
            melCompute: .cpuAndNeuralEngine,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
    }()

    let computeOptions: ModelComputeOptions

    init(computeOptions: ModelComputeOptions = Self.backgroundSafeComputeOptions) {
        self.computeOptions = computeOptions
    }

    init(computeProfile: OpenCastTranscriptionComputeProfile) {
        computeOptions = computeProfile.computeOptions
    }

    func loadRuntime(for location: OpenCastWhisperModelLocation) async throws -> any OpenCastTranscriptionRuntime {
        let config = WhisperKitConfig(
            modelFolder: location.modelFolder.path,
            tokenizerFolder: location.tokenizerFolder,
            computeOptions: computeOptions,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let runtime = try await WhisperKit(config)
        return WhisperKitTranscriptionRuntime(runtime: runtime)
    }
}
