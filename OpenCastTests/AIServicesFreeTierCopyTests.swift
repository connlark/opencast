import Testing
@testable import OpenCast

/// The strings Connor accepted for free-tier keys, word for word: a change
/// here goes back to him before it ships.
@MainActor
@Suite("AI Services free-tier copy")
struct AIServicesFreeTierCopyTests {
    private static let date = "January 1, 2027"
    private static let day = "November 7, 2026"

    @Test("The keys footer warns instead of selling the free tier")
    func keysFooter() {
        #expect(AIServicesCopy.geminiPrivacyFootnote == "Use a key from a Google project with billing set up, or an OpenAI account with credit. A key on Google's free tier is too limited for these features, and Google may use what a free-tier key sends to improve its products.")
    }

    @Test("The providers footer adds its sentence only inside the handover window")
    func providersFooter() {
        let plain = "Ad detection and Chapters & Summary run on your device and call the provider you choose with your own key. Recap and Ask use Apple's Private Cloud Compute and need no key."

        #expect(AIServicesCopy.providersFooter == plain)
        #expect(AIServicesCopy.providersFooterInHandoverWindow(date: Self.date) == "\(plain) Until January 1, 2027, when Google says a Google key is on its free tier, opencast runs ad detection on its trial service instead when that service is available.")
    }

    @Test("The key sheet says what a Google key needs and what Test found")
    func keySheet() {
        #expect(AIServicesCopy.googleKeyRequirement == "Needs a Google project with billing set up. Keys on Google's free tier are too limited for these features.")
        #expect(AIServicesCopy.testResultFreeTier == "Key works, but it is on Google's free tier, which is too limited for these features. Set up billing for its project in Google AI Studio.")
    }

    @Test("The card footnote and the Settings mark")
    func cardFootnoteAndMark() {
        #expect(AIServicesCopy.freeTierCardFootnote == "Your Google key is on Google's free tier. Using opencast's trial service.")
        #expect(AIServicesCopy.freeTierMarkInHandoverWindow(day: Self.day, date: Self.date) == "On November 7, 2026, Google answered that your Google key is on its free tier, which is too limited for ad detection. Until January 1, 2027, opencast runs ad detection on its trial service instead when that service is available. To use your key, set up billing for its project in Google AI Studio.")
        #expect(AIServicesCopy.freeTierMark(day: Self.day) == "On November 7, 2026, Google answered that your Google key is on its free tier, which is too limited for ad detection. To use your key, set up billing for its project in Google AI Studio.")
    }

    @Test("Every kind with a card message of its own is what a pass says, and none of those messages carries a code")
    func passCopy() {
        let generic = EpisodePipelineState.analysisFailedMessage(for: .generic)
        for kind in EpisodeAnalysisFailureKind.allCases {
            let card = EpisodePipelineState.analysisFailedMessage(for: kind)
            #expect(kind.passUsesCardCopy == (card != generic), "\(kind)")
            // A code reaches a message as "(code)", as a run records it.
            #expect(!card.contains("(\(kind.rawValue))"), "\(kind)")
            #expect(!card.contains("Promo/ad analysis"), "\(kind)")
        }
        #expect(!EpisodeAnalysisFailureKind.generic.passUsesCardCopy)
        #expect(!EpisodeAnalysisFailureKind.insufficientSeconds.passUsesCardCopy)
    }

    @Test("The trial status line says analysis for one and analyses otherwise")
    func trialStatusCount() {
        let tail = "Add a Gemini or OpenAI key in Settings to run ad detection and Chapters & Summary on your own account."
        #expect(AIServicesCopy.keyRequiredBody(.unitsLeft(1), trialDate: "January 1, 2027", lifetimeUnits: 5) == "You have 1 free analysis left. \(tail)")
        #expect(AIServicesCopy.keyRequiredBody(.unitsLeft(5), trialDate: "January 1, 2027", lifetimeUnits: 5) == "You have 5 free analyses left. \(tail)")
        #expect(AIServicesCopy.keyRequiredBody(.exhausted, trialDate: "January 1, 2027", lifetimeUnits: 5) == "Your 5 free analyses are used. \(tail)")
    }

    @Test("The new failure kinds are never key-required")
    func failureKindsAreNotKeyRequired() {
        for kind: EpisodeAnalysisFailureKind in [.providerDailyLimit, .providerFreeTier, .providerFreeTierRetry, .providerFreeTierRunBound] {
            #expect(kind.keyRequiredReason == nil)
        }
    }
}
