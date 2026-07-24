import Foundation

#if DEBUG
import os
#endif

enum SoundLabResponsivenessDiagnostics {
    nonisolated static let launchHoldMillisecondsEnvironmentKey =
        "OPENCAST_UI_TEST_SOUND_LAB_LAUNCH_HOLD_MILLISECONDS"

    nonisolated static func mark(_ event: String, episodeID: String? = nil) {
        #if DEBUG
        if let episodeID {
            signposter.emitEvent(
                "SoundLab",
                "\(event, privacy: .public) episodeID=\(episodeID, privacy: .public)"
            )
        } else {
            signposter.emitEvent("SoundLab", "\(event, privacy: .public)")
        }
        #endif
    }

    nonisolated static func holdLaunchPreparationIfRequested() async {
        #if DEBUG
        guard let rawValue = ProcessInfo.processInfo.environment[
            launchHoldMillisecondsEnvironmentKey
        ],
        let milliseconds = Int64(rawValue),
        milliseconds > 0
        else {
            return
        }

        try? await Task.sleep(for: .milliseconds(milliseconds))
        #endif
    }

    #if DEBUG
    private nonisolated static let signposter = OSSignposter(
        subsystem: "com.connor.opencast.perf",
        category: "SoundLabResponsiveness"
    )
    #endif
}
