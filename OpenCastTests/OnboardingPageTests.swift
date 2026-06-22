import Testing
@testable import OpenCast

@MainActor
@Suite("Onboarding pages")
struct OnboardingPageTests {
    @Test("Notification setup is the final onboarding page")
    func notificationSetupIsFinalPage() {
        #expect(OnboardingPage.allCases == [
            .welcome,
            .importOPML,
            .podcastSetup,
            .notificationSetup,
        ])
        #expect(OnboardingPage.podcastSetup.next == .notificationSetup)
        #expect(OnboardingPage.notificationSetup.next == nil)
    }

    @Test("Primary button labels match page position")
    func primaryButtonLabelsMatchPagePosition() {
        #expect(OnboardingPage.welcome.primaryActionTitle == "Continue")
        #expect(OnboardingPage.importOPML.primaryActionTitle == "Skip")
        #expect(OnboardingPage.podcastSetup.primaryActionTitle == "Continue")
        #expect(OnboardingPage.notificationSetup.primaryActionTitle == "Done")
    }
}
