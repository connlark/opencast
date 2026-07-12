import OpenCastTranscription
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode transcriber compute profile resolution")
struct OpenCastEpisodeTranscriberComputeProfileTests {
    @Test("Only the default profile upgrades, and only with background GPU granted")
    func defaultProfileUpgradesOnlyWithBackgroundGPU() {
        let cases: [(OpenCastTranscriptionComputeProfile, Bool, OpenCastTranscriptionComputeProfile)] = [
            (.backgroundSafe, true, .whisperKitDefault),
            (.backgroundSafe, false, .backgroundSafe),
            (.cpuOnly, true, .cpuOnly),
            (.cpuOnly, false, .cpuOnly),
            (.cpuAndNeuralEngine, true, .cpuAndNeuralEngine),
            (.whisperKitDefault, false, .whisperKitDefault),
        ]

        for (requested, supportsGPU, expected) in cases {
            let resolved = OpenCastEpisodeTranscriber.resolvedComputeProfile(
                requestedProfile: requested,
                supportsBackgroundGPU: supportsGPU
            )
            #expect(resolved == expected, "requested \(requested) gpu=\(supportsGPU)")
        }
    }
}
