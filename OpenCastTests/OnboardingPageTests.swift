import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Onboarding pages")
struct OnboardingPageTests {
    @Test("Every device sees the Tiny Whisper page")
    func standardPagesAlwaysIncludeWhisperStep() {
        let pages = OnboardingPage.allCases

        #expect(pages == [.welcome, .importOPML, .podcastSetup, .transcriptionModelSetup, .notificationSetup])
        #expect(OnboardingPage.welcome.previous(in: pages) == nil)
        #expect(OnboardingPage.podcastSetup.next(in: pages) == .transcriptionModelSetup)
        #expect(OnboardingPage.transcriptionModelSetup.next(in: pages) == .notificationSetup)
        #expect(OnboardingPage.transcriptionModelSetup.previous(in: pages) == .podcastSetup)
        #expect(OnboardingPage.notificationSetup.next(in: pages) == nil)
    }
}
