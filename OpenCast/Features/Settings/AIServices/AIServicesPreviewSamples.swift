import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// A preview never touches the Keychain or a provider.
enum AIServicesPreviewSamples {
    /// `savedProviders` maps a provider to whether its key syncs.
    static func appModel(savedProviders: [AnalysisProvider: Bool] = [:]) -> OpenCastAppModel {
        var seeded: [AnalysisProvider: (AnalysisProviderKey, syncs: Bool)] = [:]
        for (provider, syncs) in savedProviders {
            if let key = sampleKey(for: provider) {
                seeded[provider] = (key, syncs: syncs)
            }
        }
        return OpenCastAppModel(
            analysisPolicy: .fixed(.baked),
            analysisKeys: AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage(seeded: seeded)),
            analysisKeyTester: FixedAnalysisKeyTester(result: .accepted)
        )
    }

    static func keyRequiredRequest(_ trialStatus: AnalysisTrialStatus) -> AnalysisKeyRequiredRequest {
        AnalysisKeyRequiredRequest(id: UUID(), feature: .adDetection, trialStatus: trialStatus)
    }

    /// Assembled from parts so no source holds a key-shaped literal.
    private static func sampleKey(for provider: AnalysisProvider) -> AnalysisProviderKey? {
        switch provider {
        case .google:
            AnalysisProviderKey(["AIza", "PreviewSampleOnly", "0000000000000000"].joined())
        case .openai:
            AnalysisProviderKey(["sk-", "preview-", "sample-only-0123456789"].joined())
        }
    }
}
