#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import OpenCastPlayback
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct VoiceBoostDeviceProbe {
    static let reportFileName = "opencast-voiceboost-device-probe.json"

    private static let feedURLString = OpenCastConstants.debuggerAlmanacFeedURL
    private static let processingTimeout: TimeInterval = 45

    @discardableResult
    func writeWaitingForActiveReport(appModel: OpenCastAppModel) throws -> VoiceBoostDeviceProbeReport {
        let now = Date.now
        let applicationState = currentApplicationStateDescription()
        let initialDiagnostics = appModel.voiceBoostDiagnostics?.snapshot
        let playbackSnapshot = appModel.playback.snapshot
        let diagnosticsReport = initialDiagnostics.map(VoiceBoostDeviceProbeDiagnosticsReport.init)
        let playbackReport = VoiceBoostDeviceProbePlaybackReport(snapshot: playbackSnapshot)
        let report = VoiceBoostDeviceProbeReport(
            schemaVersion: 2,
            trigger: "launchWaitingForActive",
            startedAt: now,
            finishedAt: now,
            startedApplicationState: applicationState,
            finishedApplicationState: applicationState,
            feedURL: Self.feedURLString,
            result: "waitingForActive",
            errorMessage: "The launch-triggered Voice Boost device probe is waiting for an active scene before starting playback.",
            episodeTitle: nil,
            episodeAudioURL: nil,
            processedFramesAdvanced: false,
            timedProcessCallbacksAdvanced: false,
            audioSessionPreflight: nil,
            audioSessionFinal: nil,
            initialDiagnostics: diagnosticsReport,
            finalDiagnostics: diagnosticsReport,
            initialPlayback: playbackReport,
            finalPlayback: playbackReport
        )
        try write(report)
        return report
    }

    @discardableResult
    func run(
        trigger: String,
        appModel: OpenCastAppModel,
        modelContext: ModelContext
    ) async -> VoiceBoostDeviceProbeReport {
        let startedAt = Date.now
        let startedApplicationState = currentApplicationStateDescription()
        let initialDiagnostics = appModel.voiceBoostDiagnostics?.snapshot
        let initialPlayback = appModel.playback.snapshot
        var audioSessionPreflight: VoiceBoostDeviceProbeAudioSessionReport?
        var report: VoiceBoostDeviceProbeReport

        do {
            guard let diagnostics = appModel.voiceBoostDiagnostics else {
                throw failure("Voice Boost diagnostics were not enabled for the device probe.")
            }

            try await appModel.library.subscribe(to: Self.feedURLString, modelContext: modelContext)
            guard let episode = firstProbeEpisode(in: appModel) else {
                throw failure("The probe feed did not produce a playable episode.")
            }

            try await waitForActiveApplication()
            audioSessionPreflight = probeAudioSession(stage: "beforePlayback")
            let startingSnapshot = diagnostics.snapshot
            try await startPlayback(episode, appModel: appModel, modelContext: modelContext)
            let finalEvidence = try await waitForReleaseUsefulEvidence(
                appModel: appModel,
                diagnostics: diagnostics,
                initialProcessedFrames: startingSnapshot.processedFrameCount,
                initialTimedCallbacks: startingSnapshot.timedProcessCount
            )
            let finalDiagnostics = finalEvidence.diagnostics
            let finalPlayback = finalEvidence.playback
            let processedFramesAdvanced = finalDiagnostics.processedFrameCount > startingSnapshot.processedFrameCount
            let timedCallbacksAdvanced = finalDiagnostics.timedProcessCount > startingSnapshot.timedProcessCount
            let playbackPositionAdvanced = finalPlayback.position > 0
            let passed = processedFramesAdvanced && timedCallbacksAdvanced && playbackPositionAdvanced

            report = VoiceBoostDeviceProbeReport(
                schemaVersion: 2,
                trigger: trigger,
                startedAt: startedAt,
                finishedAt: .now,
                startedApplicationState: startedApplicationState,
                finishedApplicationState: currentApplicationStateDescription(),
                feedURL: Self.feedURLString,
                result: passed ? "passed" : "timedOut",
                errorMessage: passed
                    ? nil
                    : timeoutMessage(
                        processedFramesAdvanced: processedFramesAdvanced,
                        timedCallbacksAdvanced: timedCallbacksAdvanced,
                        playbackPositionAdvanced: playbackPositionAdvanced,
                        finalPlayback: finalPlayback
                    ),
                episodeTitle: episode.title,
                episodeAudioURL: episode.audioURL,
                processedFramesAdvanced: processedFramesAdvanced,
                timedProcessCallbacksAdvanced: timedCallbacksAdvanced,
                audioSessionPreflight: audioSessionPreflight,
                audioSessionFinal: probeAudioSession(stage: "afterPlayback"),
                initialDiagnostics: initialDiagnostics.map(VoiceBoostDeviceProbeDiagnosticsReport.init),
                finalDiagnostics: VoiceBoostDeviceProbeDiagnosticsReport(snapshot: finalDiagnostics),
                initialPlayback: VoiceBoostDeviceProbePlaybackReport(snapshot: initialPlayback),
                finalPlayback: VoiceBoostDeviceProbePlaybackReport(snapshot: finalPlayback)
            )
        } catch is CancellationError {
            report = VoiceBoostDeviceProbeReport(
                schemaVersion: 2,
                trigger: trigger,
                startedAt: startedAt,
                finishedAt: .now,
                startedApplicationState: startedApplicationState,
                finishedApplicationState: currentApplicationStateDescription(),
                feedURL: Self.feedURLString,
                result: "cancelled",
                errorMessage: "The Voice Boost device probe was cancelled.",
                episodeTitle: nil,
                episodeAudioURL: nil,
                processedFramesAdvanced: false,
                timedProcessCallbacksAdvanced: false,
                audioSessionPreflight: audioSessionPreflight,
                audioSessionFinal: probeAudioSession(stage: "cancelled"),
                initialDiagnostics: initialDiagnostics.map(VoiceBoostDeviceProbeDiagnosticsReport.init),
                finalDiagnostics: appModel.voiceBoostDiagnostics.map {
                    VoiceBoostDeviceProbeDiagnosticsReport(snapshot: $0.snapshot)
                },
                initialPlayback: VoiceBoostDeviceProbePlaybackReport(snapshot: initialPlayback),
                finalPlayback: VoiceBoostDeviceProbePlaybackReport(snapshot: appModel.playback.snapshot)
            )
        } catch {
            report = VoiceBoostDeviceProbeReport(
                schemaVersion: 2,
                trigger: trigger,
                startedAt: startedAt,
                finishedAt: .now,
                startedApplicationState: startedApplicationState,
                finishedApplicationState: currentApplicationStateDescription(),
                feedURL: Self.feedURLString,
                result: "failed",
                errorMessage: error.localizedDescription,
                episodeTitle: appModel.playback.snapshot.currentEpisode?.title,
                episodeAudioURL: appModel.playback.snapshot.currentEpisode?.audioURL?.absoluteString,
                processedFramesAdvanced: false,
                timedProcessCallbacksAdvanced: false,
                audioSessionPreflight: audioSessionPreflight,
                audioSessionFinal: probeAudioSession(stage: "failed"),
                initialDiagnostics: initialDiagnostics.map(VoiceBoostDeviceProbeDiagnosticsReport.init),
                finalDiagnostics: appModel.voiceBoostDiagnostics.map {
                    VoiceBoostDeviceProbeDiagnosticsReport(snapshot: $0.snapshot)
                },
                initialPlayback: VoiceBoostDeviceProbePlaybackReport(snapshot: initialPlayback),
                finalPlayback: VoiceBoostDeviceProbePlaybackReport(snapshot: appModel.playback.snapshot)
            )
        }

        appModel.playback.pause()

        do {
            try write(report)
        } catch {
            appModel.lastPlaybackError = "Unable to write Voice Boost device probe report: \(error.localizedDescription)"
        }

        return report
    }

    private func firstProbeEpisode(in appModel: OpenCastAppModel) -> EpisodeCacheRecord? {
        appModel.library.inboxEpisodes.first { $0.podcastID == Self.feedURLString }
            ?? appModel.library.episodes(forPodcastID: Self.feedURLString).first
    }

    private func waitForReleaseUsefulEvidence(
        appModel: OpenCastAppModel,
        diagnostics: VoiceBoostAudioTapDiagnostics,
        initialProcessedFrames: Int,
        initialTimedCallbacks: Int
    ) async throws -> (diagnostics: VoiceBoostAudioTapDiagnosticsSnapshot, playback: PlaybackSnapshot) {
        let deadline = Date.now.addingTimeInterval(Self.processingTimeout)
        var latestSnapshot = diagnostics.snapshot
        var latestPlayback = appModel.playback.snapshot

        while Date.now < deadline {
            if latestSnapshot.processedFrameCount > initialProcessedFrames,
               latestSnapshot.timedProcessCount > initialTimedCallbacks,
               latestPlayback.position > 0 {
                return (latestSnapshot, latestPlayback)
            }

            try await Task.sleep(for: .milliseconds(250))
            latestSnapshot = diagnostics.snapshot
            latestPlayback = appModel.playback.snapshot
        }

        return (latestSnapshot, latestPlayback)
    }

    private func timeoutMessage(
        processedFramesAdvanced: Bool,
        timedCallbacksAdvanced: Bool,
        playbackPositionAdvanced: Bool,
        finalPlayback: PlaybackSnapshot
    ) -> String {
        var missingEvidence: [String] = []
        if !processedFramesAdvanced {
            missingEvidence.append("processed frames")
        }
        if !timedCallbacksAdvanced {
            missingEvidence.append("timed callbacks")
        }
        if !playbackPositionAdvanced {
            missingEvidence.append("playback position")
        }

        return "Timed out before release-useful Voice Boost evidence was complete: \(missingEvidence.joined(separator: ", ")). Final playback state: \(finalPlayback.state.accessibilityDescription), position: \(finalPlayback.position)."
    }

    private func waitForActiveApplication() async throws {
        #if canImport(UIKit)
        let deadline = Date.now.addingTimeInterval(10)
        while UIApplication.shared.applicationState != .active, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        #endif
    }

    private func probeAudioSession(stage: String) -> VoiceBoostDeviceProbeAudioSessionReport {
        let applicationState = currentApplicationStateDescription()

        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        var succeeded = true
        var activationError: NSError?

        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            succeeded = false
            activationError = error as NSError
        }

        return VoiceBoostDeviceProbeAudioSessionReport(
            stage: stage,
            applicationState: applicationState,
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            routeOutputs: session.currentRoute.outputs.map(\.portType.rawValue),
            isOtherAudioPlaying: session.isOtherAudioPlaying,
            secondaryAudioShouldBeSilencedHint: session.secondaryAudioShouldBeSilencedHint,
            succeeded: succeeded,
            errorDomain: activationError?.domain,
            errorCode: activationError?.code,
            errorDescription: activationError?.localizedDescription
        )
        #else
        return VoiceBoostDeviceProbeAudioSessionReport(
            stage: stage,
            applicationState: applicationState,
            category: "unavailable",
            mode: "unavailable",
            routeOutputs: [],
            isOtherAudioPlaying: false,
            secondaryAudioShouldBeSilencedHint: false,
            succeeded: true,
            errorDomain: nil,
            errorCode: nil,
            errorDescription: nil
        )
        #endif
    }

    private func currentApplicationStateDescription() -> String {
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
        #else
        "unavailable"
        #endif
    }

    private func startPlayback(
        _ episode: EpisodeCacheRecord,
        appModel: OpenCastAppModel,
        modelContext: ModelContext
    ) async throws {
        try appModel.playEpisode(episode, modelContext: modelContext)

        for _ in 0..<4 {
            if case .failed = appModel.playback.snapshot.state {
                try await Task.sleep(for: .seconds(1))
                appModel.playback.play()
            } else {
                return
            }
        }
    }

    private func write(_ report: VoiceBoostDeviceProbeReport) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: Self.reportURL, options: [.atomic])
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "OpenCastVoiceBoostDeviceProbe",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static var reportURL: URL {
        URL.documentsDirectory.appending(path: reportFileName)
    }
}
#endif
