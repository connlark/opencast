import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Onboarding pages")
struct OnboardingPageTests {
    @Test("Every device sees the Tiny Whisper page")
    func standardPagesAlwaysIncludeWhisperStep() {
        let pages = OnboardingPage.standard

        #expect(pages == [.welcome, .importOPML, .podcastSetup, .transcriptionModelSetup, .notificationSetup])
        #expect(OnboardingPage.podcastSetup.next(in: pages) == .transcriptionModelSetup)
        #expect(OnboardingPage.transcriptionModelSetup.next(in: pages) == .notificationSetup)
        #expect(OnboardingPage.transcriptionModelSetup.previous(in: pages) == .podcastSetup)
        #expect(OnboardingPage.notificationSetup.next(in: pages) == nil)
    }

    @Test("Navigation outside the page list returns nil")
    func navigationOutsideListReturnsNil() {
        let pages: [OnboardingPage] = [.welcome, .importOPML, .podcastSetup, .notificationSetup]

        #expect(OnboardingPage.transcriptionModelSetup.next(in: pages) == nil)
        #expect(OnboardingPage.welcome.previous(in: pages) == nil)
    }

    @Test("Primary button labels match page position")
    func primaryButtonLabelsMatchPagePosition() {
        #expect(OnboardingPage.welcome.primaryActionTitle == "Continue")
        #expect(OnboardingPage.importOPML.primaryActionTitle == "Skip")
        #expect(OnboardingPage.podcastSetup.primaryActionTitle == "Continue")
        #expect(OnboardingPage.transcriptionModelSetup.primaryActionTitle == "Skip")
        #expect(OnboardingPage.notificationSetup.primaryActionTitle == "Done")
    }
}
