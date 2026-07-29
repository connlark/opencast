import Foundation

enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case importOPML
    case podcastSetup
    case transcriptionModelSetup
    case notificationSetup

    var id: Int {
        rawValue
    }

    func next(in pages: [OnboardingPage]) -> OnboardingPage? {
        guard let index = pages.firstIndex(of: self), pages.indices.contains(index + 1) else {
            return nil
        }
        return pages[index + 1]
    }

    func previous(in pages: [OnboardingPage]) -> OnboardingPage? {
        guard let index = pages.firstIndex(of: self), index > 0 else {
            return nil
        }
        return pages[index - 1]
    }

    var primaryActionTitle: String {
        switch self {
        case .welcome:
            "Continue"
        case .importOPML:
            "Skip"
        case .podcastSetup:
            "Continue"
        case .transcriptionModelSetup:
            "Skip"
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
        case .transcriptionModelSetup:
            "forward"
        case .notificationSetup:
            "checkmark"
        }
    }
}
