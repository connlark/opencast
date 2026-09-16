import SwiftUI

/// Calm explanation for every non-available state, with Apple's own
/// limit-increase flow offered only when the quota is the reason.
struct TranscriptIntelligenceUnavailableView: View {
    let availability: TranscriptIntelligenceAvailability
    var featureName = "Recap"
    var offersLimitIncrease = false
    var onRequestLimitIncrease: () -> Void = {}

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(description)
        } actions: {
            if case .quotaReached = availability, offersLimitIncrease {
                Button("Request a Higher Limit", action: onRequestLimitIncrease)
                    .buttonStyle(.glassProminent)
            }
        }
        .accessibilityIdentifier("Transcript Intelligence Unavailable")
    }

    private var title: String {
        switch availability {
        case .unsupportedDevice: "Apple Intelligence Isn’t Available"
        case .appleIntelligenceOff: "Turn On Apple Intelligence"
        case .modelNotReady: "Apple Intelligence Is Getting Ready"
        case .notEntitled: "\(featureName) Isn’t Available in This Build"
        case .offline: "You’re Offline"
        case .quotaReached: "Usage Limit Reached"
        case .available: "\(featureName) Is Ready"
        }
    }

    private var symbolName: String {
        switch availability {
        case .offline: "wifi.slash"
        case .quotaReached: "hourglass"
        default: "apple.intelligence"
        }
    }

    private var description: String {
        switch availability {
        case .unsupportedDevice:
            "\(featureName) needs a device that supports Apple Intelligence."
        case .appleIntelligenceOff:
            "\(featureName) uses Apple Intelligence. Turn it on in Settings under Apple Intelligence & Siri."
        case .modelNotReady:
            "Apple’s model isn’t ready yet. Try again in a few minutes."
        case .notEntitled:
            TranscriptIntelligenceFailure.notEntitled.userMessage ?? ""
        case .offline:
            "\(featureName) needs a connection to Apple’s Private Cloud Compute."
        case .quotaReached(let resetDate):
            if let resetDate {
                "Apple Intelligence usage limit reached. Try again \(resetDate.formatted(.relative(presentation: .named)))."
            } else {
                "Apple Intelligence usage limit reached. Try again in a few minutes."
            }
        case .available:
            ""
        }
    }
}
