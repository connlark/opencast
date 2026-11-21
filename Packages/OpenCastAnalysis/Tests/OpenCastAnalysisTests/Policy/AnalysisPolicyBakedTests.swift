import CryptoKit
import Foundation
@testable import OpenCastAnalysis
import Testing

@Suite("Baked analysis policy")
struct AnalysisPolicyBakedTests {
    @Test("Baked copy is byte-identical to the generated bundle of its version")
    func bakedCopyEqualsGeneratorOutput() throws {
        let served = try PolicyTestSupport.gatewayFile(
            "manifests/analysis-policy/v\(BakedAnalysisPolicy.bundleVersion).json"
        )
        #expect(AnalysisPolicyBundle.bakedData == served)
        let digest = SHA256.hash(data: AnalysisPolicyBundle.bakedData).map { String(format: "%02x", $0) }.joined()
        #expect(digest == BakedAnalysisPolicy.sha256)
    }

    @Test("Baked copy decodes, passes the clamp and carries the golden entries")
    func bakedCopyContents() throws {
        let bundle = AnalysisPolicyBundle.baked
        try AnalysisPolicyClamp.validate(bundle)
        #expect(bundle.schemaVersion == 1)
        #expect(bundle.bundleVersion == BakedAnalysisPolicy.bundleVersion)
        #expect(bundle.minAppBuild == 301)

        let ad = bundle.features.adDetection
        #expect(ad.policy == "promo_ad_breaks_v3")
        #expect(ad.window == .init(segments: 800, overlap: 120, maxInFlight: 4))
        #expect(ad.limits.spansPerWindow == 32)
        #expect(ad.limits.maxBreakSeconds == 600)
        #expect(ad.limits.budgetFraction == 0.40)
        #expect(ad.limits.budgetFloorSeconds == 600)
        #expect(ad.limits.evidenceWords == 32)
        #expect(ad.repair == .init(attempts: 1, feedbackBytes: 32_768))
        #expect(ad.qualifiedModels.map(\.provider) == [.google, .openai])
        #expect(ad.qualifiedModels.map(\.modelID) == ["gemini-3.8-flash", "gpt-6.1-sol"])
        #expect(ad.qualifiedModels.allSatisfy { $0.thinking == "medium" && $0.maxOutputTokens == 16_384 })
        #expect(ad.qualifiedModels.allSatisfy { $0.perCallTimeoutSeconds == 120 && $0.runBudgetSeconds == 570 })
        #expect(ad.additionalModels.map(\.identity) == [.init(provider: .google, modelID: "gemini-4-hydrogen")])
        #expect(ad.prompt.hasPrefix("Identify EVERY complete skippable advertising break"))
        guard case let .object(schema) = ad.responseSchema else {
            Issue.record("ad response schema is not an object")
            return
        }
        #expect(schema["additionalProperties"] == .bool(false))

        let chapters = bundle.features.chaptersSummary
        #expect(chapters.policy == "transcript_analysis_v2")
        #expect(chapters.allowedModels.map(\.provider) == [.google, .openai])
        #expect(chapters.allowedModels.map(\.modelID) == ["gemini-3.8-flash", "gpt-6.1-sol"])
        #expect(chapters.allowedModels.allSatisfy { $0.thinking == "medium" && $0.maxOutputTokens == 32_768 })
        #expect(chapters.allowedModels.allSatisfy { $0.perCallTimeoutSeconds == 120 && $0.runBudgetSeconds == 540 })
        #expect(chapters.additionalModels.map(\.identity) == [.init(provider: .google, modelID: "gemini-4-hydrogen")])
        #expect(chapters.coalescing == .init(aboveSegments: 1_399, unitSeconds: 5, unitChars: 700, gapSeconds: 1.5, maxUnits: 2_400))
        #expect(chapters.chapterCap == .init(min: 3, secondsPerChapter: 240))

        #expect(bundle.providers[.google]?.baseURL.host() == "generativelanguage.googleapis.com")
        #expect(bundle.providers[.openai]?.auth == .bearer)
        #expect(bundle.trial.endpoint.scheme == "https")
        #expect(bundle.trial.endpoint.host()?.hasSuffix(".opencast.mobile") == true)
        #expect(bundle.trial.startsAt == Date(timeIntervalSince1970: 1_798_761_600))
        #expect(bundle.trial.lifetimeUnits == 5)
        #expect(bundle.trial.modelID == "gemini-3.8-flash")
        // The first bundle with a notice set its start; later bundles keep it.
        #expect(bundle.notice?.startsAt == Date(timeIntervalSince1970: 1_792_890_600))
        #expect(bundle.providers[.google]?.keyURL == URL(string: "https://aistudio.google.com/app/apikey"))
        #expect(bundle.providers[.openai]?.keyURL == URL(string: "https://platform.openai.com/settings/organization/api-keys"))
        #expect(bundle.modelCards.map(\.modelID) == ["gemini-3.8-flash", "gemini-4-hydrogen", "gpt-6.1-sol"])
    }

    @Test("Snapshot resolves a policy per provider and hides Chapters without an entry")
    func snapshotResolvesPolicies() throws {
        let snapshot = AnalysisPolicySnapshot(bundle: .baked, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        let google = try #require(snapshot.adDetection(provider: .google))
        #expect(google.model.modelID == "gemini-3.8-flash")
        #expect(google.bundleVersion == BakedAnalysisPolicy.bundleVersion)
        #expect(google.settings.revision == AnalysisPolicyBundle.baked.features.adDetection.revision)
        #expect(snapshot.adDetection(provider: .openai)?.model.modelID == "gpt-6.1-sol")
        #expect(snapshot.chaptersSummary(provider: .google)?.model.modelID == "gemini-3.8-flash")
        #expect(snapshot.chaptersSummary(provider: .openai)?.model.modelID == "gpt-6.1-sol")
        #expect(snapshot.trialAdDetection?.model == google.model)

        var withSecond = AnalysisPolicyBundle.baked
        var second = withSecond.features.chaptersSummary.allowedModels[0]
        second.modelID = "gemini-second"
        withSecond.features.chaptersSummary.additionalModels = [second]
        let offering = AnalysisPolicySnapshot(bundle: withSecond, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(offering.chaptersSummary(model: .init(provider: .google, modelID: "gemini-second"))?.model == second)
        #expect(offering.chaptersSummary(model: .init(provider: .openai, modelID: "gemini-second")) == nil)
        #expect(offering.chaptersSummary(provider: .google)?.model.modelID == "gemini-3.8-flash")
        #expect(offering.modelEntries(for: .chaptersSummary, provider: .google).map(\.modelID) == ["gemini-3.8-flash", "gemini-second"])

        var withoutOpenAI = AnalysisPolicyBundle.baked
        withoutOpenAI.features.chaptersSummary.allowedModels.removeAll { $0.provider == .openai }
        let hidden = AnalysisPolicySnapshot(bundle: withoutOpenAI, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(hidden.chaptersSummary(provider: .google)?.model.modelID == "gemini-3.8-flash")
        #expect(hidden.chaptersSummary(provider: .openai) == nil)
    }

    @Test("A bundle without key pages or a notice decodes and passes the clamp")
    func olderBundleShapeDecodes() throws {
        var json = BakedAnalysisPolicy.json
        json = json.replacing(#/,\n\s*"key_url": "[^"]*"/#, with: "")
        json = json.replacing(#/,\n\s*"notice": \{\n\s*"starts_at": "[^"]*"\n\s*\}/#, with: "")
        #expect(!json.contains("key_url"))
        #expect(!json.contains("notice"))
        let bundle = try AnalysisPolicyBundle.decode(Data(json.utf8))
        #expect(bundle.providers[.google]?.keyURL == nil)
        #expect(bundle.providers[.openai]?.keyURL == nil)
        #expect(bundle.notice == nil)
        try AnalysisPolicyClamp.validate(bundle)

        let v3 = try AnalysisPolicyBundle.decode(PolicyTestSupport.gatewayFile("manifests/analysis-policy/v3.json"))
        #expect(v3.features.adDetection.additionalModels.isEmpty)
        #expect(v3.features.chaptersSummary.additionalModels.isEmpty)
        #expect(v3.modelCards.isEmpty)
        try AnalysisPolicyClamp.validate(v3)
    }

    @Test("Model entries for providers this build does not know are skipped")
    func unknownProviderEntriesAreSkipped() throws {
        var json = BakedAnalysisPolicy.json
        let entry = #"{"provider":"anthropic","model_id":"claude-x","label":"X","thinking":"medium","max_output_tokens":1,"per_call_timeout_seconds":1,"run_budget_seconds":1}"#
        json = json.replacing(#""allowed_models": ["#, with: #""allowed_models": [\#(entry),"#)
        json = json.replacing(#""providers": {"#, with: #""providers": {"anthropic": {"base_url": "x"},"#)
        let card = #"{"provider":"anthropic","model_id":"claude-x","price":"","strengths":[],"weaknesses":[]}"#
        json = json.replacing(#""model_cards": ["#, with: #""model_cards": [\#(card),"#)
        let bundle = try AnalysisPolicyBundle.decode(Data(json.utf8))
        #expect(bundle.features.chaptersSummary.allowedModels.map(\.provider) == [.google, .openai])
        #expect(bundle.providers.count == 2)
        #expect(bundle.modelCards.count == 3)
        try AnalysisPolicyClamp.validate(bundle)

        // Skipped entries still count toward the entry bound.
        let five = Array(repeating: entry, count: 5).joined(separator: ",")
        let crowded = try AnalysisPolicyBundle.decode(Data(json.replacing(#""allowed_models": ["#, with: #""allowed_models": [\#(five),"#).utf8))
        #expect(throws: AnalysisPolicyRejection.outOfBounds(field: "features.chapters_summary.additional_models")) {
            try AnalysisPolicyClamp.validate(crowded)
        }
    }
}
