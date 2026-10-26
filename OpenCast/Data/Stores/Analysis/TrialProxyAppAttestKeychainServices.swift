import Foundation

/// One App Attest slot (install id and attested key) per trial service
/// deployment, so a key registered with another service or deployment is
/// never sent to this one.
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
