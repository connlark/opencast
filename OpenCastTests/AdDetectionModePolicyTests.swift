import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad detection mode policy")
struct AdDetectionModePolicyTests {
    @Test("A completed local transcript always runs on-device")
    func completedTranscriptShortCircuits() {
        for storedMode in [AdDetectionMode.cloud, .onDevice, nil] {
            let policy = AdDetectionModePromptPolicy(
                storedMode: storedMode,
                hasCurrentCompletedTranscript: true,
                isRemoteSurfaceVisible: true
            )
            #expect(policy.decision == .runOnDevice, "stored \(String(describing: storedMode))")
        }
    }

    @Test("A stored mode runs without prompting")
    func storedModeRuns() {
        #expect(
            AdDetectionModePromptPolicy(
                storedMode: .cloud,
                hasCurrentCompletedTranscript: false,
                isRemoteSurfaceVisible: true
            ).decision == .runCloud
        )
        #expect(
            AdDetectionModePromptPolicy(
                storedMode: .onDevice,
                hasCurrentCompletedTranscript: false,
                isRemoteSurfaceVisible: true
            ).decision == .runOnDevice
        )
        // A stored cloud mode holds even when the surface is momentarily
        // invisible: the pass's own viability check owns that failure.
        #expect(
            AdDetectionModePromptPolicy(
                storedMode: .cloud,
                hasCurrentCompletedTranscript: false,
                isRemoteSurfaceVisible: false
            ).decision == .runCloud
        )
    }

    @Test("Unset mode prompts only when the remote surface is visible")
    func unsetModePromptGate() {
        #expect(
            AdDetectionModePromptPolicy(
                storedMode: nil,
                hasCurrentCompletedTranscript: false,
                isRemoteSurfaceVisible: true
            ).decision == .prompt
        )
        #expect(
            AdDetectionModePromptPolicy(
                storedMode: nil,
                hasCurrentCompletedTranscript: false,
                isRemoteSurfaceVisible: false
            ).decision == .runOnDevice
        )
    }

    @Test("Cloud-unavailable outcomes re-qualify auto detection like failures")
    func autoDetectPolicyTreatsCloudUnavailableAsFailed() {
        let policy = AdAutoDetectPlayPolicy(
            isAutoDetectEnabled: true,
            hasCurrentCompletedAnalysis: false,
            queueStatus: .cloudUnavailable(message: "No credits.")
        )
        #expect(policy.shouldEnqueue)
    }

    @Test("Cloud-unavailable status keeps the detect menu action retryable")
    func menuStateTreatsCloudUnavailableAsDetect() {
        let state = EpisodeDetectAdsMenuState(
            queueStatus: .cloudUnavailable(message: "No credits."),
            hasCurrentCompletedAnalysis: false
        )
        #expect(state == .detect)
        #expect(state.isEnabled)
    }

    @Test("Cloud stages map into the documented progress bands")
    func cloudProgressBands() {
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudQueued) == 20)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudQueued, stageElapsed: 600) == 250)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudTranscribing(nil)) == 250)
        let halfway = RemoteTranscriptionActiveProgress(
            stage: .transcribing,
            completedChunks: 2,
            totalChunks: 4,
            fractionCompleted: 0.5,
            estimate: nil
        )
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudTranscribing(halfway)) == 575)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudDetectingAds) == 910)
        #expect(
            EpisodeAdFreePassProgressMapper.units(for: .cloudDetectingAds, stageElapsed: 600) == 975
        )
        #expect(
            EpisodeAdFreePassProgressMapper.units(
                for: .cloudUnavailable(message: "off"),
                currentUnits: 400
            ) == 400
        )
    }

    @Test("Settings store persists, clears, and rolls back the mode")
    func settingsStoreRoundTrip() throws {
        let container = try ModelContainer(
            for: LocalPreferenceRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let store = AdDetectionSettingsStore()

        store.load(modelContext: context)
        #expect(store.mode == nil)

        #expect(store.setMode(.cloud, modelContext: context))
        #expect(store.mode == .cloud)

        let reloaded = AdDetectionSettingsStore()
        reloaded.load(modelContext: context)
        #expect(reloaded.mode == .cloud)

        #expect(reloaded.setMode(nil, modelContext: context))
        #expect(reloaded.mode == nil)
        let cleared = AdDetectionSettingsStore()
        cleared.load(modelContext: context)
        #expect(cleared.mode == nil)
    }

    @Test("Queue item records with an empty mode restore as on-device")
    func recordModeDecodeDefault() {
        #expect(AdDetectionMode(rawValue: "") == nil)
        #expect(AdDetectionMode(rawValue: "cloud") == .cloud)
        #expect(AdDetectionMode(rawValue: "onDevice") == .onDevice)
    }
}
