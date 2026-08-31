import Foundation

nonisolated enum TranscriptAnalysisAppAttestKeychainServices {
    static let development = "com.connor.opencast.transcript-analysis-security.development"
    static let prodStaging = "com.connor.opencast.transcript-analysis-security.prod-staging"
    static let production = "com.connor.opencast.transcript-analysis-security.production"

    static let all = [
        development,
        prodStaging,
        production
    ]
}
