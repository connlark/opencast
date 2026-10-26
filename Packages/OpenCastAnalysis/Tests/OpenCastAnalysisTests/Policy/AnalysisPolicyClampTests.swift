import Foundation
@testable import OpenCastAnalysis
import Testing

/// One bound of the clamp table: how to set it on a bundle and which field
/// the rejection must name.
struct ClampCase: Sendable, CustomTestStringConvertible {
    let field: String
    let reported: String
    let step: Double
    let set: @Sendable (inout AnalysisPolicyBundle, Double) -> Void

    var testDescription: String { field }

    init(_ field: String, reported: String? = nil, step: Double = 1, set: @escaping @Sendable (inout AnalysisPolicyBundle, Double) -> Void) {
        self.field = field
        self.reported = reported ?? field
        self.step = step
        self.set = set
    }

    static let all: [ClampCase] = [
        ClampCase("features.ad_detection.window.segments") { $0.features.adDetection.window.segments = Int($1) },
        ClampCase("features.ad_detection.window.overlap") { $0.features.adDetection.window.overlap = Int($1) },
        ClampCase("features.ad_detection.window.max_in_flight") { $0.features.adDetection.window.maxInFlight = Int($1) },
        ClampCase("features.ad_detection.limits.spans_per_window") { $0.features.adDetection.limits.spansPerWindow = Int($1) },
        ClampCase("features.ad_detection.limits.max_break_seconds", step: 0.5) { $0.features.adDetection.limits.maxBreakSeconds = $1 },
        ClampCase("features.ad_detection.limits.budget_fraction", step: 0.01) { $0.features.adDetection.limits.budgetFraction = $1 },
        ClampCase("features.ad_detection.limits.budget_floor_seconds", step: 0.5) { $0.features.adDetection.limits.budgetFloorSeconds = $1 },
        ClampCase("features.ad_detection.limits.evidence_words") { $0.features.adDetection.limits.evidenceWords = Int($1) },
        ClampCase("features.ad_detection.repair.attempts") { $0.features.adDetection.repair.attempts = Int($1) },
        ClampCase("features.ad_detection.repair.feedback_bytes") { $0.features.adDetection.repair.feedbackBytes = Int($1) },
        ClampCase(
            "features.ad_detection.qualified_models.max_output_tokens",
            reported: "features.ad_detection.qualified_models[1].max_output_tokens"
        ) { $0.features.adDetection.qualifiedModels[1].maxOutputTokens = Int($1) },
        ClampCase(
            "features.ad_detection.qualified_models.per_call_timeout_seconds",
            reported: "features.ad_detection.qualified_models[0].per_call_timeout_seconds"
        ) { bundle, value in
            bundle.features.adDetection.qualifiedModels[0].perCallTimeoutSeconds = Int(value)
            bundle.features.adDetection.qualifiedModels[0].runBudgetSeconds = 600
        },
        ClampCase(
            "features.ad_detection.qualified_models.run_budget_seconds",
            reported: "features.ad_detection.qualified_models[0].run_budget_seconds"
        ) { bundle, value in
            bundle.features.adDetection.qualifiedModels[0].perCallTimeoutSeconds = 10
            bundle.features.adDetection.qualifiedModels[0].runBudgetSeconds = Int(value)
        },
        ClampCase("features.chapters_summary.coalescing.above_segments") { $0.features.chaptersSummary.coalescing.aboveSegments = Int($1) },
        ClampCase("features.chapters_summary.coalescing.unit_seconds", step: 0.5) { $0.features.chaptersSummary.coalescing.unitSeconds = $1 },
        ClampCase("features.chapters_summary.coalescing.unit_chars") { $0.features.chaptersSummary.coalescing.unitChars = Int($1) },
        ClampCase("features.chapters_summary.coalescing.gap_seconds", step: 0.1) { $0.features.chaptersSummary.coalescing.gapSeconds = $1 },
        ClampCase("features.chapters_summary.coalescing.max_units") { $0.features.chaptersSummary.coalescing.maxUnits = Int($1) },
        ClampCase("features.chapters_summary.chapter_cap.min") { $0.features.chaptersSummary.chapterCap.min = Int($1) },
        ClampCase("features.chapters_summary.chapter_cap.seconds_per_chapter", step: 1) {
            $0.features.chaptersSummary.chapterCap.secondsPerChapter = $1
        },
        ClampCase(
            "features.chapters_summary.allowed_models.max_output_tokens",
            reported: "features.chapters_summary.allowed_models[0].max_output_tokens"
        ) { bundle, value in
            bundle.features.chaptersSummary.allowedModels = [bundle.features.adDetection.qualifiedModels[0]]
            bundle.features.chaptersSummary.allowedModels[0].maxOutputTokens = Int(value)
        },
        ClampCase(
            "features.chapters_summary.allowed_models.per_call_timeout_seconds",
            reported: "features.chapters_summary.allowed_models[0].per_call_timeout_seconds"
        ) { bundle, value in
            bundle.features.chaptersSummary.allowedModels = [bundle.features.adDetection.qualifiedModels[0]]
            bundle.features.chaptersSummary.allowedModels[0].perCallTimeoutSeconds = Int(value)
            bundle.features.chaptersSummary.allowedModels[0].runBudgetSeconds = 600
        },
        ClampCase(
            "features.chapters_summary.allowed_models.run_budget_seconds",
            reported: "features.chapters_summary.allowed_models[0].run_budget_seconds"
        ) { bundle, value in
            bundle.features.chaptersSummary.allowedModels = [bundle.features.adDetection.qualifiedModels[0]]
            bundle.features.chaptersSummary.allowedModels[0].perCallTimeoutSeconds = 10
            bundle.features.chaptersSummary.allowedModels[0].runBudgetSeconds = Int(value)
        },
        ClampCase("trial.lifetime_units") { $0.trial.lifetimeUnits = Int($1) },
    ]
}

@Suite("Analysis policy clamp")
struct AnalysisPolicyClampTests {
    private func rejection(_ mutate: (inout AnalysisPolicyBundle) -> Void) -> AnalysisPolicyRejection? {
        var bundle = AnalysisPolicyBundle.baked
        mutate(&bundle)
        do {
            try AnalysisPolicyClamp.validate(bundle)
            return nil
        } catch {
            return error
        }
    }

    @Test("Every bound in the table has a case")
    func everyBoundIsCovered() {
        #expect(Set(ClampCase.all.map(\.field)) == Set(AnalysisPolicyClamp.bounds.keys))
    }

    @Test("Each bound accepts its limits and rejects one step past either side", arguments: ClampCase.all)
    func boundIsEnforced(_ clamp: ClampCase) throws {
        let range = try #require(AnalysisPolicyClamp.bounds[clamp.field])
        #expect(rejection { clamp.set(&$0, range.upperBound + clamp.step) } == .outOfBounds(field: clamp.reported))
        #expect(rejection { clamp.set(&$0, range.lowerBound - clamp.step) } == .outOfBounds(field: clamp.reported))
        #expect(rejection { clamp.set(&$0, range.upperBound) } == nil)
        if clamp.field != "features.ad_detection.window.segments" {
            #expect(rejection { clamp.set(&$0, range.lowerBound) } == nil)
        }
    }

    @Test("The baked bundle sits at every qualified validator limit")
    func bakedSitsAtTheQualifiedLimits() {
        let ad = AnalysisPolicyBundle.baked.features.adDetection
        let bounds = AnalysisPolicyClamp.bounds
        #expect(Double(ad.window.segments) == bounds["features.ad_detection.window.segments"]?.upperBound)
        #expect(Double(ad.window.overlap) == bounds["features.ad_detection.window.overlap"]?.upperBound)
        #expect(Double(ad.window.maxInFlight) == bounds["features.ad_detection.window.max_in_flight"]?.upperBound)
        #expect(Double(ad.limits.spansPerWindow) == bounds["features.ad_detection.limits.spans_per_window"]?.upperBound)
        #expect(ad.limits.maxBreakSeconds == bounds["features.ad_detection.limits.max_break_seconds"]?.upperBound)
        #expect(ad.limits.budgetFraction == bounds["features.ad_detection.limits.budget_fraction"]?.upperBound)
        #expect(ad.limits.budgetFloorSeconds == bounds["features.ad_detection.limits.budget_floor_seconds"]?.upperBound)
        #expect(Double(ad.limits.evidenceWords) == bounds["features.ad_detection.limits.evidence_words"]?.upperBound)
        #expect(Double(ad.repair.attempts) == bounds["features.ad_detection.repair.attempts"]?.upperBound)
        #expect(Double(ad.repair.feedbackBytes) == bounds["features.ad_detection.repair.feedback_bytes"]?.upperBound)
        #expect(ad.qualifiedModels.allSatisfy {
            Double($0.maxOutputTokens) == bounds["features.ad_detection.qualified_models.max_output_tokens"]?.upperBound
        })
    }

    @Test("Clamp table equals the bounds in the served JSON schema")
    func clampMatchesSchema() throws {
        let schema = try JSONSerialization.jsonObject(
            with: PolicyTestSupport.gatewayFile("manifests/analysis-policy.schema.json")
        ) as? [String: Any]
        let root = try #require(schema)
        for (field, range) in AnalysisPolicyClamp.bounds {
            let node = try #require(Self.schemaNode(root: root, path: field), "\(field) not in schema")
            #expect((node["minimum"] as? NSNumber)?.doubleValue == range.lowerBound, "\(field) minimum")
            #expect((node["maximum"] as? NSNumber)?.doubleValue == range.upperBound, "\(field) maximum")
        }
    }

    @Test("Overlap must stay under half the window")
    func overlapUnderHalfWindow() {
        #expect(rejection {
            $0.features.adDetection.window.segments = 240
            $0.features.adDetection.window.overlap = 120
        } == .outOfBounds(field: "features.ad_detection.window.overlap"))
        #expect(rejection {
            $0.features.adDetection.window.segments = 241
            $0.features.adDetection.window.overlap = 120
        } == nil)
    }

    @Test("A run budget shorter than one call is rejected")
    func runBudgetCoversOneCall() {
        #expect(rejection {
            $0.features.adDetection.qualifiedModels[1].perCallTimeoutSeconds = 300
            $0.features.adDetection.qualifiedModels[1].runBudgetSeconds = 299
        } == .outOfBounds(field: "features.ad_detection.qualified_models[1].run_budget_seconds"))
    }

    @Test("Model entries: one per provider, path-safe ids, known thinking levels, labels")
    func modelEntryRules() {
        #expect(rejection {
            $0.features.adDetection.qualifiedModels[1] = $0.features.adDetection.qualifiedModels[0]
        } == .outOfBounds(field: "features.ad_detection.qualified_models[1].provider"))
        for badID in ["", "gpt/../x", "a?b", "a b", String(repeating: "x", count: 129)] {
            #expect(rejection {
                $0.features.adDetection.qualifiedModels[1].modelID = badID
            } == .outOfBounds(field: "features.ad_detection.qualified_models[1].model_id"))
        }
        #expect(rejection {
            $0.features.adDetection.qualifiedModels[0].thinking = "none"
        } == .outOfBounds(field: "features.ad_detection.qualified_models[0].thinking"))
        #expect(rejection { $0.features.adDetection.qualifiedModels[1].thinking = "none" } == nil)
        #expect(rejection {
            $0.features.adDetection.qualifiedModels[0].label = ""
        } == .outOfBounds(field: "features.ad_detection.qualified_models[0].label"))
    }

    @Test("Provider keys can only go to the pinned hosts over https")
    func providerHostsArePinned() {
        let foreign: [(AnalysisProvider, String)] = [
            (.openai, "https://api.example.com/v1"),
            (.openai, "http://api.openai.com/v1"),
            (.openai, "https://user@api.openai.com/v1"),
            (.openai, "https://api.openai.com:8443/v1"),
            (.google, "https://generativelanguage.googleapis.com.example.com/v1beta"),
            (.google, "https://api.openai.com/v1"),
        ]
        for (provider, url) in foreign {
            #expect(rejection {
                $0.providers[provider]?.baseURL = URL(string: url)!
            } == .outOfBounds(field: "providers.\(provider.rawValue).base_url"), "\(url)")
        }
        #expect(rejection { $0.providers[.openai]?.auth = .googleAPIKey } == .outOfBounds(field: "providers.openai.auth"))
        #expect(rejection {
            $0.providers[.google]?.generatePath = "/../upload"
        } == .outOfBounds(field: "providers.google.generate_path"))
        #expect(rejection {
            $0.providers[.openai]?.countTokensPath = "/responses?key=1"
        } == .outOfBounds(field: "providers.openai.count_tokens_path"))
        #expect(rejection {
            $0.providers[.openai]?.versionHeaders = ["Authorization": "Bearer x"]
        } == .outOfBounds(field: "providers.openai.version_headers"))
        #expect(rejection { $0.providers[.openai]?.versionHeaders = ["openai-beta": "x"] } == nil)
        #expect(rejection { $0.providers[.openai] = nil } == .outOfBounds(field: "providers.openai"))
    }

    @Test("Key pages follow the shared cases on their raw text, and may be absent")
    func keyPagesFollowTheSharedCases() throws {
        struct Cases: Decodable {
            let accepted: [String]
            let rejected: [String]
        }
        let cases = try JSONDecoder().decode(
            Cases.self,
            from: PolicyTestSupport.gatewayFile("tests/fixtures/analysis-policy-key-pages.json")
        )
        #expect(!cases.accepted.isEmpty && !cases.rejected.isEmpty)
        for page in cases.accepted {
            #expect(rejection { $0.providers[.google]?.keyPage = page } == nil, "\(page)")
        }
        for page in cases.rejected {
            #expect(rejection {
                $0.providers[.google]?.keyPage = page
            } == .outOfBounds(field: "providers.google.key_url"), "\(page)")
        }
        #expect(rejection { $0.providers[.openai]?.keyPage = nil } == nil)
    }

    @Test("A key page decodes as its raw text, and opens as a URL")
    func keyPageDecodesRaw() throws {
        let json = BakedAnalysisPolicy.json.replacing(
            "https://aistudio.google.com/app/apikey",
            with: "https://example.com/{keys}"
        )
        let bundle = try AnalysisPolicyBundle.decode(Data(json.utf8))
        #expect(bundle.providers[.google]?.keyPage == "https://example.com/{keys}")
        #expect(bundle.providers[.google]?.keyURL != nil)
        try AnalysisPolicyClamp.validate(bundle)
    }

    @Test("Trial endpoint stays on opencast.mobile and names a Google ad-detection entry")
    func trialRules() {
        #expect(rejection {
            $0.trial.endpoint = URL(string: "https://trial.example.com")!
        } == .outOfBounds(field: "trial.endpoint"))
        #expect(rejection {
            $0.trial.endpoint = URL(string: $0.trial.endpoint.absoluteString.replacing("https:", with: "http:"))!
        } == .outOfBounds(field: "trial.endpoint"))
        #expect(rejection { $0.trial.modelID = "gpt-6.1-sol" } == .outOfBounds(field: "trial.model"))
    }

    @Test("Text fields and format version")
    func textAndFormat() {
        #expect(rejection { $0.features.adDetection.prompt = "" } == .outOfBounds(field: "features.ad_detection.prompt"))
        #expect(rejection {
            $0.features.chaptersSummary.prompt = String(repeating: "a", count: AnalysisPolicyClamp.maximumPromptBytes + 1)
        } == .outOfBounds(field: "features.chapters_summary.prompt"))
        // Under the limit in characters, over it in UTF-8 bytes.
        #expect(rejection {
            $0.features.chaptersSummary.prompt = String(repeating: "\u{E9}", count: 40_000)
        } == .outOfBounds(field: "features.chapters_summary.prompt"))
        #expect(rejection {
            $0.features.adDetection.responseSchema = .object(["description": .string(String(repeating: "x", count: 70_000))])
        } == .outOfBounds(field: "features.ad_detection.response_schema"))
        #expect(rejection {
            $0.features.adDetection.responseSchema = .string("{}")
        } == .outOfBounds(field: "features.ad_detection.response_schema"))
        #expect(rejection { $0.schemaVersion = 2 } == .unsupportedSchemaVersion(2))
        #expect(rejection { $0.bundleVersion = 0 } == .outOfBounds(field: "bundle_version"))
    }

    /// Follows a bundle JSON path through `properties`, `items` and `$ref`.
    private static func schemaNode(root: [String: Any], path: String) -> [String: Any]? {
        func resolve(_ node: [String: Any]) -> [String: Any]? {
            guard let reference = node["$ref"] as? String else { return node }
            var target: Any? = root
            for component in reference.dropFirst(2).split(separator: "/") {
                target = (target as? [String: Any])?[String(component)]
            }
            return (target as? [String: Any]).flatMap(resolve)
        }
        var node: [String: Any]? = root
        for component in path.split(separator: ".") {
            guard var current = node.flatMap(resolve) else { return nil }
            if current["properties"] == nil, let items = current["items"] as? [String: Any] {
                current = resolve(items) ?? [:]
            }
            node = (current["properties"] as? [String: Any])?[String(component)] as? [String: Any]
        }
        return node.flatMap(resolve)
    }
}
