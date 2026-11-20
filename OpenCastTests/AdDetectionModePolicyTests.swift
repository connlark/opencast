import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad detection mode policy")
struct AdDetectionModePolicyTests {
    @Test(
        "A completed transcript attached to the trusted download always runs on-device",
        arguments: [AdDetectionMode.cloud, nil]
    )
    func attachedCompletedTranscriptShortCircuits(storedMode: AdDetectionMode?) {
        let policy = AdDetectionModePromptPolicy(
            storedMode: storedMode,
            hasAttachedCompletedTranscript: true,
            isRemoteSurfaceVisible: true
        )
        #expect(policy.decision == .runOnDevice)
    }

    @Test(
        "A detached transcript follows the stored mode or prompts, as an untranscribed episode does",
        arguments: [
            (AdDetectionMode?.some(.onDevice), true, AdDetectionModePromptPolicy.Decision.runOnDevice),
            (.some(.cloud), true, .runCloud),
            (.some(.cloud), false, .runCloud),
            (nil, true, .prompt),
            (nil, false, .runOnDevice)
        ]
    )
    func detachedTranscriptFollowsTheMode(
        storedMode: AdDetectionMode?,
        isRemoteSurfaceVisible: Bool,
        expected: AdDetectionModePromptPolicy.Decision
    ) {
        let policy = AdDetectionModePromptPolicy(
            storedMode: storedMode,
            hasAttachedCompletedTranscript: false,
            isRemoteSurfaceVisible: isRemoteSurfaceVisible
        )
        #expect(policy.decision == expected)
    }

    @Test("Unset mode prompts only when the remote surface is visible")
    func unsetModePromptGate() {
        #expect(
            AdDetectionModePromptPolicy(
                storedMode: nil,
                hasAttachedCompletedTranscript: false,
                isRemoteSurfaceVisible: true
            ).decision == .prompt
        )
        #expect(
            AdDetectionModePromptPolicy(
                storedMode: nil,
                hasAttachedCompletedTranscript: false,
                isRemoteSurfaceVisible: false
            ).decision == .runOnDevice
        )
    }

    @Test("Cloud stages map into the documented progress bands")
    func cloudProgressBands() {
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudQueued) == 20)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudWaitingForCredits, stageElapsed: 600) == 250)
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudTranscribing(nil)) == 250)
        let halfway = RemoteTranscriptionActiveProgress(
            stage: .transcribing,
            completedChunks: 2,
            totalChunks: 4,
            fractionCompleted: 0.5,
            estimate: nil
        )
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudTranscribing(halfway)) == 575)
        // The server finishing the transcript creeps up to, never into, the
        // band of the device ad detection that follows it.
        #expect(EpisodeAdFreePassProgressMapper.units(for: .cloudFinishing) == 900)
        #expect(
            EpisodeAdFreePassProgressMapper.units(for: .cloudFinishing, stageElapsed: 600) == 909
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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
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
