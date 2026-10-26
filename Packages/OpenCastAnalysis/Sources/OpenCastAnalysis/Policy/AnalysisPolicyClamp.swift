import Foundation

/// The app's hard bounds on every bundle value. Each maximum is the limit the
/// workers' validators were qualified with (`analysis-policy.schema.json`
/// states the same numbers and the generator's tests tie them to the worker
/// constants), so a signed bundle may only tighten. One value out of bounds
/// rejects the whole bundle. Widening a bound is an app release plus the
/// golden suite.
public enum AnalysisPolicyClamp {
    /// Inclusive bounds by JSON path. Model-entry paths cover every entry in
    /// the list.
    public static let bounds: [String: ClosedRange<Double>] = [
        "features.ad_detection.window.segments": 200...800,
        "features.ad_detection.window.overlap": 60...120,
        "features.ad_detection.window.max_in_flight": 1...4,
        "features.ad_detection.limits.spans_per_window": 1...32,
        "features.ad_detection.limits.max_break_seconds": 15...600,
        "features.ad_detection.limits.budget_fraction": 0...0.40,
        "features.ad_detection.limits.budget_floor_seconds": 0...600,
        "features.ad_detection.limits.evidence_words": 2...32,
        "features.ad_detection.repair.attempts": 0...1,
        "features.ad_detection.repair.feedback_bytes": 1...32_768,
        "features.ad_detection.qualified_models.max_output_tokens": 1_024...16_384,
        "features.ad_detection.qualified_models.per_call_timeout_seconds": 10...300,
        "features.ad_detection.qualified_models.run_budget_seconds": 10...600,
        "features.chapters_summary.coalescing.above_segments": 1_399...1_399,
        "features.chapters_summary.coalescing.unit_seconds": 5...5,
        "features.chapters_summary.coalescing.unit_chars": 700...700,
        "features.chapters_summary.coalescing.gap_seconds": 1.5...1.5,
        "features.chapters_summary.coalescing.max_units": 1...2_400,
        "features.chapters_summary.chapter_cap.min": 1...3,
        "features.chapters_summary.chapter_cap.seconds_per_chapter": 240...300,
        "features.chapters_summary.allowed_models.max_output_tokens": 1_024...32_768,
        "features.chapters_summary.allowed_models.per_call_timeout_seconds": 10...300,
        "features.chapters_summary.allowed_models.run_budget_seconds": 10...600,
        "trial.lifetime_units": 0...5,
    ]

    /// Longest prompt, in UTF-8 bytes.
    public static let maximumPromptBytes = 65_536
    /// Largest response schema, in UTF-8 bytes of its compact JSON.
    public static let maximumResponseSchemaBytes = 65_536
    /// Longest picker label, in Unicode scalars.
    public static let maximumLabelScalars = 64
    public static let maximumVersionHeaders = 8

    /// Checks every value and relation; the first violation rejects the
    /// bundle. Does not check `minAppBuild` (the baked copy is exempt).
    public static func validate(_ bundle: AnalysisPolicyBundle) throws(AnalysisPolicyRejection) {
        guard bundle.schemaVersion == 1 else {
            throw .unsupportedSchemaVersion(bundle.schemaVersion)
        }
        guard bundle.bundleVersion >= 1 else { throw .outOfBounds(field: "bundle_version") }
        guard bundle.minAppBuild >= 0 else { throw .outOfBounds(field: "min_app_build") }
        try validate(bundle.features.adDetection)
        try validate(bundle.features.chaptersSummary)
        try validateProviders(bundle)
        try validateTrial(bundle)
    }

    private static func validate(_ ad: AdDetectionPolicy) throws(AnalysisPolicyRejection) {
        let path = "features.ad_detection"
        try check(ad.window.segments, "\(path).window.segments")
        try check(ad.window.overlap, "\(path).window.overlap")
        guard 2 * ad.window.overlap < ad.window.segments else {
            throw .outOfBounds(field: "\(path).window.overlap")
        }
        try check(ad.window.maxInFlight, "\(path).window.max_in_flight")
        try check(ad.limits.spansPerWindow, "\(path).limits.spans_per_window")
        try check(ad.limits.maxBreakSeconds, "\(path).limits.max_break_seconds")
        try check(ad.limits.budgetFraction, "\(path).limits.budget_fraction")
        try check(ad.limits.budgetFloorSeconds, "\(path).limits.budget_floor_seconds")
        try check(ad.limits.evidenceWords, "\(path).limits.evidence_words")
        try check(ad.repair.attempts, "\(path).repair.attempts")
        try check(ad.repair.feedbackBytes, "\(path).repair.feedback_bytes")
        try validateText(policy: ad.policy, revision: ad.revision, prompt: ad.prompt, schema: ad.responseSchema, path: path)
        try validate(ad.qualifiedModels, path: "\(path).qualified_models")
    }

    private static func validate(_ chapters: ChaptersSummaryPolicy) throws(AnalysisPolicyRejection) {
        let path = "features.chapters_summary"
        try check(chapters.coalescing.aboveSegments, "\(path).coalescing.above_segments")
        try check(chapters.coalescing.unitSeconds, "\(path).coalescing.unit_seconds")
        try check(chapters.coalescing.unitChars, "\(path).coalescing.unit_chars")
        try check(chapters.coalescing.gapSeconds, "\(path).coalescing.gap_seconds")
        try check(chapters.coalescing.maxUnits, "\(path).coalescing.max_units")
        try check(chapters.chapterCap.min, "\(path).chapter_cap.min")
        try check(chapters.chapterCap.secondsPerChapter, "\(path).chapter_cap.seconds_per_chapter")
        try validateText(
            policy: chapters.policy,
            revision: chapters.revision,
            prompt: chapters.prompt,
            schema: chapters.responseSchema,
            path: path
        )
        try validate(chapters.allowedModels, path: "\(path).allowed_models")
    }

    private static func validate(_ entries: [AnalysisModelEntry], path: String) throws(AnalysisPolicyRejection) {
        var providers: Set<AnalysisProvider> = []
        for (index, entry) in entries.enumerated() {
            let entryPath = "\(path)[\(index)]"
            guard providers.insert(entry.provider).inserted else {
                throw .outOfBounds(field: "\(entryPath).provider")
            }
            guard isValidModelID(entry.modelID) else { throw .outOfBounds(field: "\(entryPath).model_id") }
            guard (1...maximumLabelScalars).contains(entry.label.unicodeScalars.count) else {
                throw .outOfBounds(field: "\(entryPath).label")
            }
            guard entry.provider.thinkingLevels.contains(entry.thinking) else {
                throw .outOfBounds(field: "\(entryPath).thinking")
            }
            try check(entry.maxOutputTokens, "\(path).max_output_tokens", reported: "\(entryPath).max_output_tokens")
            try check(
                entry.perCallTimeoutSeconds,
                "\(path).per_call_timeout_seconds",
                reported: "\(entryPath).per_call_timeout_seconds"
            )
            try check(entry.runBudgetSeconds, "\(path).run_budget_seconds", reported: "\(entryPath).run_budget_seconds")
            guard entry.runBudgetSeconds >= entry.perCallTimeoutSeconds else {
                throw .outOfBounds(field: "\(entryPath).run_budget_seconds")
            }
        }
    }

    private static func validateText(
        policy: String,
        revision: String,
        prompt: String,
        schema: AnalysisPolicyJSON,
        path: String
    ) throws(AnalysisPolicyRejection) {
        guard (1...64).contains(policy.unicodeScalars.count) else { throw .outOfBounds(field: "\(path).policy") }
        guard (1...64).contains(revision.unicodeScalars.count) else { throw .outOfBounds(field: "\(path).revision") }
        guard (1...maximumPromptBytes).contains(prompt.utf8.count) else {
            throw .outOfBounds(field: "\(path).prompt")
        }
        guard case .object = schema,
              let schemaBytes = try? schema.sortedKeysData().count,
              schemaBytes <= maximumResponseSchemaBytes
        else {
            throw .outOfBounds(field: "\(path).response_schema")
        }
    }

    private static func validateProviders(_ bundle: AnalysisPolicyBundle) throws(AnalysisPolicyRejection) {
        let used = Set(bundle.features.adDetection.qualifiedModels.map(\.provider))
            .union(bundle.features.chaptersSummary.allowedModels.map(\.provider))
        for provider in used where bundle.providers[provider] == nil {
            throw .outOfBounds(field: "providers.\(provider.rawValue)")
        }
        for (provider, endpoint) in bundle.providers {
            let path = "providers.\(provider.rawValue)"
            guard httpsHost(endpoint.baseURL) == provider.pinnedHost else {
                throw .outOfBounds(field: "\(path).base_url")
            }
            let expectedAuth: AnalysisProviderEndpoint.Auth = provider == .google ? .googleAPIKey : .bearer
            guard endpoint.auth == expectedAuth else { throw .outOfBounds(field: "\(path).auth") }
            guard isSafePath(endpoint.generatePath) else { throw .outOfBounds(field: "\(path).generate_path") }
            guard isSafePath(endpoint.countTokensPath) else {
                throw .outOfBounds(field: "\(path).count_tokens_path")
            }
            if let keyPage = endpoint.keyPage, !isValidKeyPage(keyPage) {
                throw .outOfBounds(field: "\(path).key_url")
            }
            guard endpoint.versionHeaders.count <= maximumVersionHeaders,
                  endpoint.versionHeaders.allSatisfy(isSafeVersionHeader)
            else {
                throw .outOfBounds(field: "\(path).version_headers")
            }
        }
    }

    private static func validateTrial(_ bundle: AnalysisPolicyBundle) throws(AnalysisPolicyRejection) {
        let trial = bundle.trial
        guard let host = httpsHost(trial.endpoint), host == "opencast.mobile" || host.hasSuffix(".opencast.mobile") else {
            throw .outOfBounds(field: "trial.endpoint")
        }
        try check(trial.lifetimeUnits, "trial.lifetime_units")
        let namesGoogleAdEntry = bundle.features.adDetection.qualifiedModels.contains {
            $0.provider == .google && $0.modelID == trial.modelID
        }
        guard namesGoogleAdEntry else { throw .outOfBounds(field: "trial.model") }
    }

    private static func check(_ value: Int, _ field: String, reported: String? = nil) throws(AnalysisPolicyRejection) {
        try check(Double(value), field, reported: reported)
    }

    private static func check(_ value: Double, _ field: String, reported: String? = nil) throws(AnalysisPolicyRejection) {
        guard let range = bounds[field], value.isFinite, range.contains(value) else {
            throw .outOfBounds(field: reported ?? field)
        }
    }

    /// Model ids are interpolated into request paths: 1-128 of `[A-Za-z0-9._-]`.
    static func isValidModelID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    /// A key page, checked on the bundle's raw text exactly as the generator
    /// checks it (before any `URL` normalises it): at most 256 bytes,
    /// `https://`, a host of lowercase letters, digits, dots and hyphens,
    /// then nothing or a safe path, so no user info, port, query, fragment,
    /// encoded byte or non-ASCII character passes.
    static func isValidKeyPage(_ raw: String) -> Bool {
        let scheme = "https://"
        guard raw.utf8.count <= 256, raw.hasPrefix(scheme) else { return false }
        let rest = raw.dropFirst(scheme.count)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let host = rest[..<slash]
        let path = String(rest[slash...])
        let hostIsValid = !host.isEmpty && host.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D
        }
        return hostIsValid && (path.isEmpty || isSafePath(path))
    }

    /// The host of an `https` URL with no user info, port, query or fragment.
    static func httpsHost(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              components.path.isEmpty || isSafePath(components.path)
        else {
            return nil
        }
        return host
    }

    /// Visible ASCII only, as the generator requires.
    static func isSafePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 256 && path.utf8.allSatisfy { $0 >= 0x21 && $0 < 0x7F }
            && !path.contains("..") && !path.contains("//")
            && !path.contains(where: { "?#\\@% ".contains($0) || $0.isNewline })
    }

    private static func isSafeVersionHeader(_ header: (key: String, value: String)) -> Bool {
        let forbidden: Set<String> = ["authorization", "x-goog-api-key", "x-api-key", "cookie", "host"]
        let name = header.key.lowercased()
        let nameIsToken = (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
        let valueIsPrintable = (1...256).contains(header.value.utf8.count)
            && header.value.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return nameIsToken && valueIsPrintable && !forbidden.contains(name)
    }
}
