import Foundation

nonisolated enum AdAnalysisAppAttestKeychainServices {
    static let development = "com.connor.opencast.ad-analysis-security.development"
    static let prodStaging = "com.connor.opencast.ad-analysis-security.prod-staging"
    static let production = "com.connor.opencast.ad-analysis-security.production"

    static let all = [
        development,
        prodStaging,
        production
    ]
}
