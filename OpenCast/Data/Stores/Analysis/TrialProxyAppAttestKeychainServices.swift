import Foundation

/// One slot per deployment, so a key registered with another deployment is never sent here.
nonisolated enum TrialProxyAppAttestKeychainServices {
    static let development = "com.connor.opencast.trial-proxy-security.development"
    static let prodStaging = "com.connor.opencast.trial-proxy-security.prod-staging"
    static let production = "com.connor.opencast.trial-proxy-security.production"

    static let all = [
        development,
        prodStaging,
        production
    ]
}
