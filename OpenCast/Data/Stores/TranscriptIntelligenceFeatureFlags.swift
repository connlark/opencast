import Foundation

/// `isEnabled` is live in Release, so each later operation ships behind its own sub-flag until
/// its stage closes.
enum TranscriptIntelligenceFeatureFlags {
    nonisolated static let isEnabled = true
    nonisolated static let isAskEnabled = true

    #if DEBUG
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
