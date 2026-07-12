import CoreML
@preconcurrency import WhisperKit

public enum OpenCastTranscriptionComputeProfile: String, Sendable, Equatable {
    case backgroundSafe
    case cpuOnly
    case cpuAndNeuralEngine
    /// WhisperKit's own defaults (GPU-backed mel). Only safe where the
    /// platform grants background GPU — callers opt in per decision 16;
    /// the package default stays `backgroundSafe`.
    case whisperKitDefault

    var computeOptions: ModelComputeOptions {
        switch self {
        case .backgroundSafe:
            WhisperKitTranscriptionRuntimeLoader.backgroundSafeComputeOptions
        case .cpuOnly:
            ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly
            )
        case .cpuAndNeuralEngine:
            ModelComputeOptions(
                melCompute: .cpuAndNeuralEngine,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .whisperKitDefault:
            ModelComputeOptions()
        }
    }

    public var logDescription: String {
        switch self {
        case .backgroundSafe:
            "backgroundSafe"
        case .cpuOnly:
            "cpuOnly"
        case .cpuAndNeuralEngine:
            "cpuAndNE"
        case .whisperKitDefault:
            "whisperKitDefault"
        }
    }
}
