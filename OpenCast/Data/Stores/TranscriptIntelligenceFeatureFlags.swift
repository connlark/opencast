import Foundation

/// Gate for the Private Cloud Compute transcript features (Recap, Ask).
/// Entry points stay hidden while `isEnabled` is false; it is the one
/// switch that removes the feature from a build. Each later operation ships
/// behind its own sub-flag until its stage closes, because the main flag is
/// live in Release builds.
enum TranscriptIntelligenceFeatureFlags {
    nonisolated static let isEnabled = true
    nonisolated static let isAskEnabled = true

    #if DEBUG
    /// Lights the feature for one process regardless of `isEnabled`, so
    /// device QA and UI tests keep working if the flag is ever turned off.
    nonisolated static let enableArgument = "--transcript-intelligence-enabled"
    nonisolated static let enableEnvironmentKey = "OPENCAST_TRANSCRIPT_INTELLIGENCE_ENABLED"
    nonisolated static let enableAskArgument = "--transcript-intelligence-ask-enabled"
    nonisolated static let enableAskEnvironmentKey = "OPENCAST_TRANSCRIPT_INTELLIGENCE_ASK_ENABLED"
    #endif

    nonisolated static var isEnabledForProcess: Bool {
        #if DEBUG
        if isRequested(argument: enableArgument, environmentKey: enableEnvironmentKey) {
            return true
        }
        #endif
        return isEnabled
    }

    /// Ask needs the main flag as well; its override never lights Recap.
    nonisolated static var isAskEnabledForProcess: Bool {
        guard isEnabledForProcess else {
            return false
        }
        #if DEBUG
        if isRequested(argument: enableAskArgument, environmentKey: enableAskEnvironmentKey) {
            return true
        }
        #endif
        return isAskEnabled
    }

    #if DEBUG
    private nonisolated static func isRequested(argument: String, environmentKey: String) -> Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(argument) || processInfo.environment[environmentKey] == "1"
    }
    #endif
}
