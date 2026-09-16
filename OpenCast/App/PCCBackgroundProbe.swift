#if DEBUG
@preconcurrency import BackgroundTasks
import Foundation
import FoundationModels
import OSLog
import UIKit

/// Launch-arg probe: does a Private Cloud Compute call succeed while the app is
/// backgrounded under a `BGContinuedProcessingTask`? Writes a JSON report to
/// `Documents/pcc-bg-probe.json`; an optional full window request at
/// `Documents/pcc-bg-probe.request.json` (helper input format) runs in the
/// background phase when present.
enum PCCBackgroundProbe {
    nonisolated static let requestArgument = "--pcc-bg-probe"
    nonisolated static let requestEnvironmentKey = "OPENCAST_PCC_BG_PROBE"
    nonisolated static let reasoningArgument = "--pcc-bg-probe-reasoning"
    nonisolated static let lockPauseArgument = "--pcc-bg-probe-lock-pause"

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "PCCBackgroundProbe")
    private static let backgroundWaitLimit: Duration = .seconds(180)
    private static let builtInRequest = ProbeRequest(
        label: "built-in-small",
        instructions: "Reply in one short sentence.",
        prompt: "Say hello and name the company that built you.",
        schema: nil,
        maxOutputTokens: 64
    )

    struct ProbeRequest {
        var label: String
        var instructions: String?
        var prompt: String
        var schema: [String: Any]?
        var maxOutputTokens: Int?
    }

    @MainActor private static var hasStarted = false
    @MainActor private static var hasRegistered = false
    @MainActor private static var report: [String: Any] = [:]
    @MainActor private static var steps: [[String: Any]] = []
    @MainActor private static var activeHandle: (any AdFreePassContinuedTaskHandle)?
    @MainActor private static var workTask: Task<Void, Never>?

    nonisolated static var isRequested: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains(requestArgument)
            || processInfo.environment[requestEnvironmentKey] == "1"
    }

    @MainActor
    static func runIfRequested() {
        guard isRequested, !hasStarted else {
            return
        }
        hasStarted = true
        Task { @MainActor in
            await start()
        }
    }

    @MainActor
    private static func start() async {
        try? FileManager.default.removeItem(at: reportURL)
        steps = []
        report = [
            "started_at": Date.now.ISO8601Format(),
            "device_model": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
            "reasoning": reasoningName,
            "lock_pause_s": lockPauseSeconds,
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "has_request_file": FileManager.default.fileExists(atPath: requestURL.path),
            "background_refresh": UIApplication.shared.backgroundRefreshStatus.rawValue,
        ]
        let pcc = PrivateCloudComputeLanguageModel()
        report["pcc_availability"] = availabilityString(pcc.availability)
        report["pcc_quota_initial"] = quotaDictionary(pcc.quotaUsage)
        if let contextSize = try? await pcc.contextSize {
            report["pcc_context_size"] = contextSize
        }
        save()
        logger.log("probe started availability=\(availabilityString(pcc.availability), privacy: .public)")

        await runCall(phase: "foreground-small", request: builtInRequest)
        if foregroundWindows > 0, let fileRequest = loadRequestFile() {
            for index in 0..<foregroundWindows {
                await runCall(phase: "foreground-window-\(index + 1)", request: fileRequest)
            }
        }

        let scheduler = BGTaskSchedulerAdFreePassScheduler()
        let identifier = EpisodeAdFreePassBackgroundSession.identifier
        if !hasRegistered {
            hasRegistered = scheduler.registerLaunchHandler(identifier: identifier) { handle in
                handleLaunch(handle)
            }
        }
        note("registration", ["result": hasRegistered, "identifier": identifier])
        guard hasRegistered else {
            finish(reason: "registration-failed")
            return
        }
        do {
            try scheduler.submit(
                identifier: identifier,
                title: "Skip Promos & Ads",
                subtitle: "PCC background probe",
                requiresGPU: false
            )
            note("submitted", ["state": appState])
        } catch {
            note("submission-failed", ["error": error.localizedDescription])
            finish(reason: "submission-failed")
        }
    }

    @MainActor
    private static func handleLaunch(_ handle: any AdFreePassContinuedTaskHandle) {
        note("launch-handler", ["state": appState])
        activeHandle = handle
        handle.progress.totalUnitCount = 1000
        handle.progress.completedUnitCount = 10
        handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: waiting for background")
        handle.setExpirationHandler {
            Task { @MainActor in
                note("expired", ["state": appState, "protected_data": UIApplication.shared.isProtectedDataAvailable])
                workTask?.cancel()
                workTask = nil
                activeHandle?.setTaskCompleted(success: false)
                activeHandle = nil
                finish(reason: "expired")
            }
        }

        workTask?.cancel()
        workTask = Task { @MainActor in
            let clock = ContinuousClock()
            let waitStart = clock.now
            var progress: Int64 = 10
            while UIApplication.shared.applicationState != .background, clock.now - waitStart < backgroundWaitLimit {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                progress = min(progress + 1, 100)
                handle.progress.completedUnitCount = progress
            }
            note("background-wait", ["state": appState, "waited_s": seconds(clock.now - waitStart)])
            handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: small call in background")
            handle.progress.completedUnitCount = 150
            await runCall(phase: "background-small", request: builtInRequest)
            guard !Task.isCancelled else { return }

            if let fileRequest = loadRequestFile() {
                for repeatIndex in 0..<max(windowRepeats, 1) {
                    handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: full window in background \(repeatIndex + 1)/\(windowRepeats)")
                    handle.progress.completedUnitCount = 300 + Int64(repeatIndex)
                    await runCall(phase: repeatIndex == 0 ? "background-window" : "background-window-\(repeatIndex + 1)", request: fileRequest)
                    guard !Task.isCancelled else { return }
                    if lastStepWasRateLimited, retrySeconds > 0 {
                        // Find the recovery time: small call every 20 s.
                        let retryStart = clock.now
                        var attempt = 0
                        var recovered = false
                        while clock.now - retryStart < .seconds(retrySeconds) {
                            do {
                                try await Task.sleep(for: .seconds(20))
                            } catch {
                                return
                            }
                            attempt += 1
                            handle.progress.completedUnitCount = 500 + Int64(attempt)
                            handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: rate-limit retry \(attempt)")
                            await runCall(phase: "retry-small-\(attempt)", request: builtInRequest)
                            if (steps.last?["ok"] as? Bool) == true {
                                note("rate-limit-recovered", ["after_s": seconds(clock.now - retryStart), "attempt": attempt])
                                recovered = true
                                break
                            }
                        }
                        if !recovered {
                            note("rate-limit-not-recovered", ["within_s": retrySeconds])
                        }
                        await runCall(phase: "post-recovery-window", request: fileRequest)
                        break
                    }
                }
            }

            if lockPauseSeconds > 0 {
                handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: lock the device now (\(lockPauseSeconds)s)")
                handle.progress.completedUnitCount = 700
                note("lock-pause-start", ["state": appState, "protected_data": UIApplication.shared.isProtectedDataAvailable])
                // Keep reporting progress during the wait: a continued
                // processing task that goes quiet for ~75 s was expired by
                // the system on the first iPhone run.
                var protectedTransitions: [[String: Any]] = []
                var lastProtected = UIApplication.shared.isProtectedDataAvailable
                var didRunLockedCalls = false
                for tick in 1...lockPauseSeconds {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    handle.progress.completedUnitCount = 700 + Int64(200 * tick / lockPauseSeconds)
                    handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: lock the device now (\(lockPauseSeconds - tick)s)")
                    let protectedNow = UIApplication.shared.isProtectedDataAvailable
                    if protectedNow != lastProtected {
                        protectedTransitions.append(["tick": tick, "protected_data": protectedNow, "at": Date.now.ISO8601Format()])
                        lastProtected = protectedNow
                    }
                    // Fire the real test the moment the device locks: PCC calls
                    // while protected data is unavailable.
                    if !protectedNow, !didRunLockedCalls {
                        didRunLockedCalls = true
                        handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: calling PCC while locked")
                        await runCall(phase: "locked-small", request: builtInRequest)
                        if let fileRequest = loadRequestFile() {
                            await runCall(phase: "locked-window", request: fileRequest)
                        }
                        guard !Task.isCancelled else { return }
                    }
                }
                note("lock-pause-transitions", ["transitions": protectedTransitions])
                note("lock-pause-end", ["state": appState, "protected_data": UIApplication.shared.isProtectedDataAvailable])
                handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe: call after lock pause")
                await runCall(phase: "background-after-lock-pause", request: builtInRequest)
                guard !Task.isCancelled else { return }
            }

            handle.progress.completedUnitCount = 1000
            handle.updateTitle("Skip Promos & Ads", subtitle: "PCC probe complete")
            handle.setTaskCompleted(success: true)
            activeHandle = nil
            workTask = nil
            finish(reason: "completed")
        }
    }

    @MainActor
    private static func runCall(phase: String, request: ProbeRequest) async {
        let pcc = PrivateCloudComputeLanguageModel()
        var step: [String: Any] = [
            "phase": phase,
            "label": request.label,
            "started_at": Date.now.ISO8601Format(),
            "state_start": appState,
            "protected_data_start": UIApplication.shared.isProtectedDataAvailable,
            "availability": availabilityString(pcc.availability),
            "quota_before": quotaDictionary(pcc.quotaUsage),
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "prompt_chars": request.prompt.count,
            "status": "running",
        ]
        steps.append(step)
        save()
        let stepIndex = steps.count - 1

        let session = LanguageModelSession(model: pcc, tools: [], instructions: request.instructions)
        let options = GenerationOptions(maximumResponseTokens: request.maxOutputTokens)
        let contextOptions = ContextOptions(includeSchemaInPrompt: true, reasoningLevel: reasoningLevel)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            if let schemaJSON = request.schema {
                let schema = try GenerationSchema(root: try buildSchema(schemaJSON, name: "Response"), dependencies: [])
                let response = try await session.respond(
                    to: request.prompt,
                    schema: schema,
                    options: options,
                    contextOptions: contextOptions
                )
                step["raw_json"] = response.rawContent.jsonString
                step["usage"] = usageDictionary(response.usage)
            } else {
                let response = try await session.respond(
                    to: request.prompt,
                    options: options,
                    contextOptions: contextOptions
                )
                step["content"] = response.content
                step["usage"] = usageDictionary(response.usage)
            }
            step["ok"] = true
            step["status"] = "ok"
        } catch {
            step["ok"] = false
            step["status"] = "failed"
            step["error"] = errorDictionary(error)
        }
        step["elapsed_s"] = seconds(clock.now - start)
        step["state_end"] = appState
        step["protected_data_end"] = UIApplication.shared.isProtectedDataAvailable
        step["quota_after"] = quotaDictionary(pcc.quotaUsage)
        step["finished_at"] = Date.now.ISO8601Format()
        steps[stepIndex] = step
        save()
        logger.log("probe call phase=\(phase, privacy: .public) ok=\(step["ok"] as? Bool ?? false, privacy: .public)")
    }

    // MARK: - Report plumbing

    @MainActor
    private static func note(_ event: String, _ fields: [String: Any]) {
        var entry = fields
        entry["event"] = event
        entry["at"] = Date.now.ISO8601Format()
        var events = report["events"] as? [[String: Any]] ?? []
        events.append(entry)
        report["events"] = events
        save()
        logger.log("probe event \(event, privacy: .public)")
    }

    @MainActor
    private static func finish(reason: String) {
        report["finished_at"] = Date.now.ISO8601Format()
        report["finish_reason"] = reason
        report["pcc_quota_final"] = quotaDictionary(PrivateCloudComputeLanguageModel().quotaUsage)
        save()
    }

    @MainActor
    private static func save() {
        report["steps"] = steps
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .atomic)
        } catch {
            logger.error("probe report write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var reportURL: URL {
        URL.documentsDirectory.appending(path: "pcc-bg-probe.json")
    }

    private static var requestURL: URL {
        URL.documentsDirectory.appending(path: "pcc-bg-probe.request.json")
    }

    @MainActor
    private static func loadRequestFile() -> ProbeRequest? {
        guard let data = try? Data(contentsOf: requestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prompt = object["prompt"] as? String else {
            return nil
        }
        return ProbeRequest(
            label: object["label"] as? String ?? "request-file",
            instructions: object["instructions"] as? String,
            prompt: prompt,
            schema: object["schema"] as? [String: Any],
            maxOutputTokens: object["max_output_tokens"] as? Int
        )
    }

    @MainActor
    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private nonisolated static var reasoningName: String {
        argumentValue(flag: reasoningArgument) ?? "light"
    }

    private nonisolated static var reasoningLevel: ContextOptions.ReasoningLevel? {
        switch reasoningName {
        case "light": .light
        case "moderate": .moderate
        case "deep": .deep
        case "none": nil
        default: .custom(reasoningName)
        }
    }

    nonisolated static let windowRepeatsArgument = "--pcc-bg-probe-window-repeats"
    nonisolated static let foregroundWindowsArgument = "--pcc-bg-probe-foreground-windows"
    nonisolated static let retrySecondsArgument = "--pcc-bg-probe-retry-seconds"

    private nonisolated static var foregroundWindows: Int {
        Int(argumentValue(flag: foregroundWindowsArgument) ?? "") ?? 0
    }

    private nonisolated static var retrySeconds: Int {
        Int(argumentValue(flag: retrySecondsArgument) ?? "") ?? 0
    }

    @MainActor
    private static var lastStepWasRateLimited: Bool {
        guard let last = steps.last, (last["ok"] as? Bool) == false,
              let error = last["error"] as? [String: Any] else {
            return false
        }
        return (error["kind"] as? String) == "rateLimited"
    }

    private nonisolated static var windowRepeats: Int {
        Int(argumentValue(flag: windowRepeatsArgument) ?? "") ?? 1
    }

    private nonisolated static var lockPauseSeconds: Int {
        Int(argumentValue(flag: lockPauseArgument) ?? "") ?? 0
    }

    private nonisolated static func argumentValue(flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(flag)=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - FoundationModels helpers (mirrors the macOS PCCProbe helper)

    private nonisolated static func buildSchema(_ json: [String: Any], name: String) throws -> DynamicGenerationSchema {
        let type = json["type"] as? String ?? "object"
        let description = json["description"] as? String
        switch type {
        case "object":
            let required = Set((json["required"] as? [String]) ?? [])
            var properties: [DynamicGenerationSchema.Property] = []
            if let list = json["properties"] as? [[Any]] {
                for pair in list {
                    guard pair.count == 2, let propertyName = pair[0] as? String, let sub = pair[1] as? [String: Any] else {
                        throw ProbeError.schema("bad ordered property in \(name)")
                    }
                    let subSchema = try buildSchema(sub, name: "\(name)_\(propertyName)")
                    properties.append(DynamicGenerationSchema.Property(
                        name: propertyName,
                        description: sub["description"] as? String,
                        schema: subSchema,
                        isOptional: !required.contains(propertyName)
                    ))
                }
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)
        case "array":
            guard let items = json["items"] as? [String: Any] else {
                throw ProbeError.schema("array without items in \(name)")
            }
            return DynamicGenerationSchema(
                arrayOf: try buildSchema(items, name: "\(name)_item"),
                minimumElements: json["minItems"] as? Int,
                maximumElements: json["maxItems"] as? Int
            )
        case "string":
            if let choices = json["enum"] as? [String] {
                return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            throw ProbeError.schema("unsupported type \(type) in \(name)")
        }
    }

    private enum ProbeError: Error {
        case schema(String)
    }

    private nonisolated static func quotaDictionary(_ quota: PrivateCloudComputeLanguageModel.QuotaUsage) -> [String: Any] {
        var dictionary: [String: Any] = ["isLimitReached": quota.isLimitReached]
        switch quota.status {
        case .belowLimit(let below):
            dictionary["status"] = "belowLimit"
            dictionary["isApproachingLimit"] = below.isApproachingLimit
        case .limitReached:
            dictionary["status"] = "limitReached"
        @unknown default:
            dictionary["status"] = "unknown"
        }
        if let reset = quota.resetDate {
            dictionary["resetDate"] = reset.ISO8601Format()
        }
        dictionary["hasLimitIncreaseSuggestion"] = quota.limitIncreaseSuggestion != nil
        return dictionary
    }

    private nonisolated static func availabilityString(_ availability: PrivateCloudComputeLanguageModel.Availability) -> String {
        switch availability {
        case .available: "available"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }

    private nonisolated static func usageDictionary(_ usage: LanguageModelSession.Usage) -> [String: Any] {
        [
            "input_total": usage.input.totalTokenCount,
            "input_cached": usage.input.cachedTokenCount,
            "output_total": usage.output.totalTokenCount,
            "output_reasoning": usage.output.reasoningTokenCount,
            "total": usage.totalTokenCount,
        ]
    }

    private nonisolated static func errorDictionary(_ error: any Error) -> [String: Any] {
        var dictionary: [String: Any] = [
            "description": String(describing: error),
            "localized": error.localizedDescription,
            "swift_type": String(describing: type(of: error)),
        ]
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded(let detail):
                dictionary["kind"] = "contextSizeExceeded"
                dictionary["contextSize"] = detail.contextSize
                dictionary["tokenCount"] = detail.tokenCount
                dictionary["debug"] = detail.debugDescription
            case .rateLimited(let detail):
                dictionary["kind"] = "rateLimited"
                if let reset = detail.resetDate { dictionary["resetDate"] = reset.ISO8601Format() }
                dictionary["debug"] = detail.debugDescription
            case .guardrailViolation(let detail):
                dictionary["kind"] = "guardrailViolation"
                dictionary["debug"] = detail.debugDescription
            case .refusal(let detail):
                dictionary["kind"] = "refusal"
                dictionary["debug"] = detail.debugDescription
            case .unsupportedCapability(let detail):
                dictionary["kind"] = "unsupportedCapability"
                dictionary["debug"] = detail.debugDescription
            case .unsupportedTranscriptContent(let detail):
                dictionary["kind"] = "unsupportedTranscriptContent"
                dictionary["debug"] = detail.debugDescription
            case .unsupportedGenerationGuide(let detail):
                dictionary["kind"] = "unsupportedGenerationGuide"
                dictionary["debug"] = detail.debugDescription
            case .unsupportedLanguageOrLocale(let detail):
                dictionary["kind"] = "unsupportedLanguageOrLocale"
                dictionary["debug"] = detail.debugDescription
            case .timeout(let detail):
                dictionary["kind"] = "timeout"
                dictionary["debug"] = detail.debugDescription
            @unknown default:
                dictionary["kind"] = "languageModelError.unknown"
            }
        } else if let pccError = error as? PrivateCloudComputeLanguageModel.Error {
            switch pccError {
            case .networkFailure(let detail):
                dictionary["kind"] = "pcc.networkFailure"
                dictionary["debug"] = detail.debugDescription
            case .quotaLimitReached(let detail):
                dictionary["kind"] = "pcc.quotaLimitReached"
                if let reset = detail.resetDate { dictionary["resetDate"] = reset.ISO8601Format() }
                dictionary["debug"] = detail.debugDescription
            case .serviceUnavailable(let detail):
                dictionary["kind"] = "pcc.serviceUnavailable"
                dictionary["debug"] = detail.debugDescription
            @unknown default:
                dictionary["kind"] = "pcc.unknown"
            }
        }
        let nsError = error as NSError
        dictionary["ns_domain"] = nsError.domain
        dictionary["ns_code"] = nsError.code
        if let underlying = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            dictionary["underlying"] = underlying.map {
                ["domain": $0.domain, "code": $0.code, "description": $0.localizedDescription, "userInfo": String(describing: $0.userInfo)]
            }
        }
        return dictionary
    }
}
#endif
