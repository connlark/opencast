import Foundation

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case importOPML
    case podcastSetup
    case notificationSetup

    var id: Int {
        rawValue
    }

    var next: OnboardingPage? {
        Self(rawValue: rawValue + 1)
    }

    var previous: OnboardingPage? {
        Self(rawValue: rawValue - 1)
    }

    var primaryActionTitle: String {
        switch self {
        case .welcome:
            "Continue"
        case .importOPML:
            "Skip"
        case .podcastSetup:
            "Continue"
        case .notificationSetup:
            "Done"
        }
    }

    var primaryActionSystemImage: String {
        switch self {
        case .welcome:
            "chevron.right"
        case .importOPML:
            "forward"
        case .podcastSetup:
            "chevron.right"
        case .notificationSetup:
            "checkmark"
        }
    }
}
