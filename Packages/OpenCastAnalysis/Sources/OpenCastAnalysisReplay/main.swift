import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

// Replays recorded model answers through the on-device analysis pipeline
// and prints what it built and decided, as JSON on stdout. Network-free,
// except `live` and `key-test`, which call a provider with a key.

let usage = """
usage: OpenCastAnalysisReplay <command> [options]

  render   --feature ads|chapters --fixture REQUEST.json [--thinking LEVEL]
           The canonical payload of every window (ads) or the prepared
           request and both attempt payloads (chapters).
  validate --feature ads|chapters --request REQUEST.json --response REPLY
           [--window] [--answer | --openai]
           Parse and validate one recorded reply. REPLY is a raw Gemini
           body, with --answer a normalized answer
           {"texts": [...], "finish_reason": ..., "usage": {...}}, or with
           --openai a raw Responses body as the OpenAI transport reads it.
  run      --feature ads|chapters --fixture REQUEST.json --replies REPLIES.json
           --model MODEL [--thinking LEVEL] [--in-flight N]
           Whole-episode replay through AnalysisRunner. REPLIES maps
           "window-N" / "repair-N" (ads) or "attempt-N" (chapters) to
           {"body": "..."} or {"answer": {...}}; absent means not recorded.

  char-classes
           What the receipt tokenizer and trimming make of every Unicode
           scalar, in the shape of the ad bridge's char_classes op.

  live     --feature ads|chapters --fixture REQUEST.json --provider google|openai
           --model ID [--thinking LEVEL] --key-file PATH --out DIR
           [--spend-hook EXECUTABLE] [--max-sends N]
           One real run through AnalysisRunner with the provider transport.
           Writes request.json, input-count.json, exchanges/ (each request
           and response as structured fields only: kind and body out;
           status, content type, Retry-After seconds, answer text, usage
           numbers and closed error fields back; never a URL, header or
           provider message; each file verified whole for every fragment of
           the key or replaced by a placeholder), transport.log and
           outcome.json under DIR. The spend
           hook is consulted before and after every exchange (reserve, then
           settle, release or ambiguous); a refused reservation is never
           sent. At most N generate requests are sent (default 16).
  key-test --provider google|openai --model ID --key-file PATH --out DIR
           [--spend-hook EXECUTABLE]
           The provider's cheapest authenticated call.

  reproject --provider google|openai --key-file PATH --exchanges DIR --out DIR
           Rewrites exchanges recorded in the earlier form (raw bodies) as
           today's structured records, through the live recorder's own
           functions. Prints counts only.

  audit    --key-files PATH[,PATH] --root DIR
           Counts only: how the recorder sink treats every JSON and log file
           under DIR with those keys registered (strings and names its
           fragment check flags, files it would suppress, log lines it would
           redact). Prints no key, fragment or artifact text.

  --policy reference selects the built-in policy (the default and only one).
  --thinking none omits the thinking level (ads).
"""

struct Arguments {
    var command: String
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws(AnalysisReplay.InputError) {
        guard let command = arguments.first else { throw AnalysisReplay.InputError(description: usage) }
        self.command = command
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw AnalysisReplay.InputError(description: "unexpected \(argument)") }
            let name = String(argument.dropFirst(2))
            if ["window", "answer", "openai"].contains(name) {
                flags.insert(name)
                index += 1
            } else {
                guard index + 1 < arguments.count else {
                    throw AnalysisReplay.InputError(description: "missing value for \(argument)")
                }
                options[name] = arguments[index + 1]
                index += 2
            }
        }
    }

    func required(_ name: String) throws(AnalysisReplay.InputError) -> String {
        guard let value = options[name] else { throw AnalysisReplay.InputError(description: "missing --\(name)") }
        return value
    }

    func checkPolicyName() throws(AnalysisReplay.InputError) {
        let name = options["policy"] ?? "reference"
        guard name == "reference" else { throw AnalysisReplay.InputError(description: "unknown policy \(name)") }
    }

    /// The canonical thinking level for ads: `--thinking none` omits it.
    var canonicalThinking: String? {
        guard let value = options["thinking"] else { return AnalysisModelEntry.serviceAdDetection.thinking }
        return value == "none" || value == "null" ? nil : value
    }

    /// The ad-analysis service's policy, with --model and --in-flight applied.
    var adPolicy: AdDetectionAnalysisPolicy {
        let service = AdDetectionAnalysisPolicy.service
        var settings = service.settings
        if let inFlight = options["in-flight"].flatMap(Int.init) { settings.window.maxInFlight = inFlight }
        var model = service.model
        if let id = options["model"] { model.modelID = id }
        if let thinking = canonicalThinking { model.thinking = thinking }
        return service.with(settings: settings, model: model)
    }

    /// The Chapters & Summary service's policy, with --model and --thinking applied.
    var chaptersPolicy: ChaptersSummaryAnalysisPolicy {
        let service = ChaptersSummaryAnalysisPolicy.service
        var model = service.model
        if let id = options["model"] { model.modelID = id }
        if let level = options["thinking"], level != "none" { model.thinking = level }
        return service.with(model: model)
    }
}

func readJSON(_ path: String) throws -> JSONValue {
    try JSONParser.parse(try String(contentsOfFile: path, encoding: .utf8))
}

func execute(_ arguments: Arguments) async throws -> JSONValue {
    if arguments.command == "char-classes" { return AnalysisReplay.characterClasses() }
    if arguments.command == "key-test" { return try await LiveRun(arguments: arguments).keyTest() }
    if arguments.command == "live" { return try await LiveRun(arguments: arguments).live() }
    if arguments.command == "audit" { return try Audit(arguments: arguments).run() }
    if arguments.command == "reproject" { return try Reproject(arguments: arguments).run() }
    try arguments.checkPolicyName()
    let feature = try arguments.required("feature")
    guard feature == "ads" || feature == "chapters" else {
        throw AnalysisReplay.InputError(description: "unknown feature \(feature)")
    }
    switch arguments.command {
    case "render":
        let fixture = try readJSON(try arguments.required("fixture"))
        return feature == "ads"
            ? AnalysisReplay.renderAds(
                try AdAnalysisRequest(json: fixture),
                policy: arguments.adPolicy,
                canonicalThinking: arguments.canonicalThinking
            )
            : AnalysisReplay.renderChapters(try TranscriptAnalysisRequest(json: fixture), policy: arguments.chaptersPolicy)
    case "validate":
        let request = try readJSON(try arguments.required("request"))
        let path = try arguments.required("response")
        let reply: AnalysisProviderReply = if arguments.flags.contains("answer") {
            .answer(try AnalysisReplay.providerAnswer(try readJSON(path)))
        } else if arguments.flags.contains("openai") {
            .answer(OpenAIResponsesMapping.answer(fromBody: try String(contentsOfFile: path, encoding: .utf8)).answer)
        } else {
            .geminiBody(try String(contentsOfFile: path, encoding: .utf8))
        }
        return feature == "ads"
            ? AnalysisReplay.validateAds(
                try AdAnalysisRequest(json: request),
                reply: reply,
                window: arguments.flags.contains("window"),
                policy: arguments.adPolicy
            )
            : AnalysisReplay.validateChapters(
                try TranscriptAnalysisRequest(json: request),
                reply: reply,
                policy: arguments.chaptersPolicy
            )
    case "run":
        let fixture = try readJSON(try arguments.required("fixture"))
        let replies = try AnalysisReplay.replies(try readJSON(try arguments.required("replies")))
        return feature == "ads"
            ? await AnalysisReplay.runAds(
                try AdAnalysisRequest(json: fixture),
                replies: replies,
                policy: arguments.adPolicy,
                canonicalThinking: arguments.canonicalThinking
            )
            : await AnalysisReplay.runChapters(
                try TranscriptAnalysisRequest(json: fixture),
                replies: replies,
                policy: arguments.chaptersPolicy
            )
    default:
        throw AnalysisReplay.InputError(description: usage)
    }
}

do {
    let result = try await execute(try Arguments(Array(CommandLine.arguments.dropFirst())))
    FileHandle.standardOutput.write(Data((JSONWriter.string(result) + "\n").utf8))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(64)
}
