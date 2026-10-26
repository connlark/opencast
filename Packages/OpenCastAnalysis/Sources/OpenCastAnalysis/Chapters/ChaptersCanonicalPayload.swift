/// The Chapters & Summary prompt and canonical payload: one request per
/// episode, the transcript as `[id | start-end] text` lines.
public enum ChaptersCanonicalPayload {
    /// An absent or empty title falls back to the id.
    static func titleOrID(_ title: String?, _ id: String) -> String {
        if let title, !title.isEmpty { return title }
        return id
    }

    public static func prompt(_ request: TranscriptAnalysisRequest, policy: ChaptersSummaryPolicy) -> String {
        var text = policy.prompt
        text += "\n\n"
        text += "Policy: \(policy.policy)\n"
        text += "Episode: \(titleOrID(request.episodeTitle, request.episodeID))\n"
        text += "Podcast: \(titleOrID(request.podcastTitle, request.podcastID))\n"
        text += "Language: \(request.transcript.languageCode)\n"
        text += "Audio duration: \(RustFloatFormat.fixed(request.transcript.audioDuration, places: 3))s\n\n"
        text += "Segments:\n"
        for segment in request.segments {
            text += "[\(segment.id) | \(RustFloatFormat.fixed(segment.start, places: 3))-\(RustFloatFormat.fixed(segment.end, places: 3))] \(segment.text)\n"
        }
        return text
    }

    public static func payload(
        _ request: TranscriptAnalysisRequest,
        policy: ChaptersSummaryPolicy,
        maxOutputTokens: Int,
        thinking: String
    ) -> JSONValue {
        JSONValue.object([
            "contents": .array([
                .object([
                    "role": .string("user"),
                    "parts": .array([.object(["text": .string(prompt(request, policy: policy))])]),
                ]),
            ]),
            "generationConfig": .object([
                "temperature": .integer(0),
                "topP": .double(0.95),
                "maxOutputTokens": .integer(maxOutputTokens),
                "responseMimeType": .string("application/json"),
                "responseJsonSchema": JSONValue(policy.responseSchema),
                "thinkingConfig": .object(["thinkingLevel": .string(thinking)]),
            ]),
        ]).sortedKeys()
    }

    /// The first request's thinking level: the base level up to the
    /// escalation threshold of model-facing ids, the escalated level above.
    public static func baseThinking(
        modelSegmentCount: Int,
        model: AnalysisModelEntry,
        policy: ChaptersSummaryPolicy
    ) -> String {
        modelSegmentCount > ChaptersPipelineConstants.escalationSegmentCount
            ? ChaptersPipelineConstants.escalatedThinking
            : model.thinking
    }
}
