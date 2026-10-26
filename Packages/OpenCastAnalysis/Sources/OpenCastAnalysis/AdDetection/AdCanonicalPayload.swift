/// The provider-neutral request for one window, in Gemini `generateContent`
/// shape: the system instruction, one user turn holding the window as JSON
/// with timestamps stripped, the response schema, the output cap and the
/// thinking level. Transports map it to their provider's wire format.
public enum AdCanonicalPayload {
    /// The user turn: policy, titles (or ids), language and `{id, text}`
    /// segments. Times are deliberately absent; ids have one meaning.
    public static func input(_ request: AdAnalysisRequest, policy: AdDetectionPolicy) -> String {
        let value = JSONValue.object([
            "policy": .string(policy.policy),
            "episode": .string(request.episodeTitle ?? request.episodeID),
            "podcast": .string(request.podcastTitle ?? request.podcastID),
            "language": .string(request.transcript.languageCode),
            "segments": .array(request.segments.map { segment in
                .object(["id": .number(.integer(segment.id)), "text": .string(segment.text)])
            }),
        ])
        return JSONWriter.string(value.sortedKeys())
    }

    /// The canonical payload for one window.
    public static func payload(
        _ request: AdAnalysisRequest,
        policy: AdDetectionPolicy,
        maxOutputTokens: Int,
        thinking: String?
    ) -> JSONValue {
        var config: [JSONMember] = [
            JSONMember("maxOutputTokens", .integer(maxOutputTokens)),
            JSONMember("responseMimeType", .string("application/json")),
            JSONMember("responseJsonSchema", JSONValue(policy.responseSchema)),
        ]
        if let thinking {
            config.append(JSONMember("thinkingConfig", .object(["thinkingLevel": .string(thinking)])))
        }
        return JSONValue.object([
            "systemInstruction": .object(["parts": .array([.object(["text": .string(policy.prompt)])])]),
            "contents": .array([
                .object([
                    "role": .string("user"),
                    "parts": .array([.object(["text": .string(input(request, policy: policy))])]),
                ]),
            ]),
            "generationConfig": .object(config),
        ]).sortedKeys()
    }
}

extension [JSONMember] {
    /// Replaces the first member named `key`, or appends one.
    mutating func setMember(_ key: String, _ value: JSONValue) {
        if let index = firstIndex(where: { $0.key == key }) {
            self[index].value = value
        } else {
            append(JSONMember(key, value))
        }
    }

    mutating func updateMember(_ key: String, _ update: (inout JSONValue) -> Void) {
        guard let index = firstIndex(where: { $0.key == key }) else { return }
        update(&self[index].value)
    }

    mutating func updateObjectMember(_ key: String, _ update: (inout [JSONMember]) -> Void) {
        updateMember(key) { value in
            guard case .object(var members) = value else { return }
            update(&members)
            value = .object(members)
        }
    }
}

extension JSONValue {
    mutating func updateObjectMember(_ key: String, _ update: (inout [JSONMember]) -> Void) {
        guard case .object(var members) = self else { return }
        members.updateObjectMember(key, update)
        self = .object(members)
    }
}
